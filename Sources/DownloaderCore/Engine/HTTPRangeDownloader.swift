import Foundation

public struct ProbeResult: Sendable {
    public let totalBytes: Int64
    public let acceptRanges: Bool
    public let etag: String?
    public let lastModified: String?
    public let suggestedFilename: String?
}

public protocol HTTPRangeDownloaderDelegate: AnyObject, Sendable {
    func downloaderDidUpdateProgress(taskId: UUID, totalBytes: Int64, downloadedBytes: Int64, speed: Double)
    func downloaderDidComplete(taskId: UUID, finalURL: URL)
    func downloaderDidFail(taskId: UUID, error: Error)
}

public actor HTTPRangeDownloader {
    private let session: URLSession
    private let speedTracker = SpeedTracker()
    private var isPaused = false
    private var isCancelled = false

    public static func makeOptimizedSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 32
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 86400
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    public init(session: URLSession? = nil) {
        self.session = session ?? Self.makeOptimizedSession()
    }

    public static func probeURL(
        url: URL,
        customHeaders: [String: String]? = nil,
        cookies: String? = nil,
        userAgent: String? = nil,
        session: URLSession? = nil
    ) async throws -> ProbeResult {
        let activeSession = session ?? makeOptimizedSession()
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        if let headers = customHeaders {
            for (key, val) in headers { request.setValue(val, forHTTPHeaderField: key) }
        }
        if let cookies = cookies, !cookies.isEmpty {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }
        if let ua = userAgent, !ua.isEmpty {
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
        }

        let (_, response) = try await activeSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        // If HEAD fails or gives no length, try a Range 0-0 GET probe
        if httpResponse.statusCode >= 400 || httpResponse.expectedContentLength <= 0 {
            var getRequest = URLRequest(url: url)
            getRequest.httpMethod = "GET"
            getRequest.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            if let headers = customHeaders {
                for (key, val) in headers { getRequest.setValue(val, forHTTPHeaderField: key) }
            }
            if let cookies = cookies, !cookies.isEmpty {
                getRequest.setValue(cookies, forHTTPHeaderField: "Cookie")
            }
            if let ua = userAgent, !ua.isEmpty {
                getRequest.setValue(ua, forHTTPHeaderField: "User-Agent")
            }

            let (_, getResponse) = try await activeSession.data(for: getRequest)
            if let getHTTP = getResponse as? HTTPURLResponse {
                return parseHeaders(from: getHTTP, url: url)
            }
        }

        return parseHeaders(from: httpResponse, url: url)
    }

    private static func parseHeaders(from response: HTTPURLResponse, url: URL) -> ProbeResult {
        let headers = response.allHeaderFields

        var acceptRanges = false
        if let accept = headers["Accept-Ranges"] as? String, accept.lowercased().contains("bytes") {
            acceptRanges = true
        } else if response.statusCode == 206 {
            acceptRanges = true
        }

        var totalBytes: Int64 = response.expectedContentLength
        if let contentRange = headers["Content-Range"] as? String {
            acceptRanges = true
            let parts = contentRange.split(separator: "/")
            if parts.count == 2, let parsed = Int64(parts[1]) {
                totalBytes = parsed
            }
        }

        let etag = headers["ETag"] as? String
        let lastModified = headers["Last-Modified"] as? String

        var suggestedFilename: String?
        if let disposition = headers["Content-Disposition"] as? String {
            suggestedFilename = parseFilename(from: disposition)
        }
        if suggestedFilename == nil || suggestedFilename?.isEmpty == true {
            let last = url.lastPathComponent
            suggestedFilename = last.isEmpty ? "download" : last
        }

        return ProbeResult(
            totalBytes: totalBytes,
            acceptRanges: acceptRanges,
            etag: etag,
            lastModified: lastModified,
            suggestedFilename: suggestedFilename
        )
    }

    private static func parseFilename(from contentDisposition: String) -> String? {
        let items = contentDisposition.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        for item in items {
            if item.lowercased().hasPrefix("filename*=") {
                let val = item.dropFirst("filename*=".count)
                if let utf8Part = val.split(separator: "''").last {
                    return String(utf8Part).removingPercentEncoding ?? String(utf8Part)
                }
            } else if item.lowercased().hasPrefix("filename=") {
                var val = String(item.dropFirst("filename=".count))
                if val.hasPrefix("\"") && val.hasSuffix("\"") {
                    val = String(val.dropFirst().dropLast())
                }
                return val
            }
        }
        return nil
    }

    public static func calculateSegments(
        taskId: UUID,
        totalBytes: Int64,
        segmentCount: Int,
        acceptRanges: Bool
    ) -> [DownloadSegment] {
        guard acceptRanges, totalBytes > 0, segmentCount > 1 else {
            return [
                DownloadSegment(
                    taskId: taskId,
                    index: 0,
                    startByte: 0,
                    endByte: totalBytes > 0 ? totalBytes - 1 : -1,
                    downloadedBytes: 0,
                    status: .pending
                )
            ]
        }

        let count = max(1, min(segmentCount, 32))
        let chunkSize = totalBytes / Int64(count)
        var segments: [DownloadSegment] = []

        for i in 0..<count {
            let start = Int64(i) * chunkSize
            let end = (i == count - 1) ? (totalBytes - 1) : (start + chunkSize - 1)
            segments.append(
                DownloadSegment(
                    taskId: taskId,
                    index: i,
                    startByte: start,
                    endByte: end,
                    downloadedBytes: 0,
                    status: .pending
                )
            )
        }

        return segments
    }

    public func download(
        task: DownloadTask,
        segments: [DownloadSegment],
        onProgress: @escaping @Sendable (Int64, Double) -> Void,
        onSegmentUpdate: @escaping @Sendable (DownloadSegment) -> Void
    ) async throws {
        isPaused = false
        isCancelled = false
        speedTracker.reset()

        let fileManager = FileManager.default
        let destDir = task.destinationFolder
        if !fileManager.fileExists(atPath: destDir.path) {
            try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
        }

        // Direct sparse file allocation on APFS: pre-allocate total size instantly
        let targetFile = task.finalFilePath
        if !fileManager.fileExists(atPath: targetFile.path) {
            fileManager.createFile(atPath: targetFile.path, contents: nil)
            if task.totalBytes > 0 {
                let initHandle = try FileHandle(forWritingTo: targetFile)
                try initHandle.truncate(atOffset: UInt64(task.totalBytes))
                try initHandle.close()
            }
        }

        var updatedSegments = segments

        try await withThrowingTaskGroup(of: DownloadSegment.self) { group in
            for segment in updatedSegments {
                group.addTask { [self] in
                    try await self.downloadSegmentDirect(
                        segment: segment,
                        task: task,
                        targetFile: targetFile,
                        onProgress: onProgress,
                        onSegmentUpdate: onSegmentUpdate
                    )
                }
            }

            for try await completedSeg in group {
                if let idx = updatedSegments.firstIndex(where: { $0.id == completedSeg.id }) {
                    updatedSegments[idx] = completedSeg
                }
            }
        }

        // Clean up temporary checkpoint directory if any
        try? fileManager.removeItem(at: task.tempDirectory)
    }

    private func downloadSegmentDirect(
        segment: DownloadSegment,
        task: DownloadTask,
        targetFile: URL,
        onProgress: @escaping @Sendable (Int64, Double) -> Void,
        onSegmentUpdate: @escaping @Sendable (DownloadSegment) -> Void
    ) async throws -> DownloadSegment {
        var currentSegment = segment

        if currentSegment.expectedBytes > 0 && currentSegment.downloadedBytes >= currentSegment.expectedBytes {
            currentSegment.status = .completed
            onSegmentUpdate(currentSegment)
            return currentSegment
        }

        var request = URLRequest(url: task.url)
        request.httpMethod = "GET"
        if let ref = task.referrer { request.setValue(ref, forHTTPHeaderField: "Referer") }
        if let ua = task.userAgent { request.setValue(ua, forHTTPHeaderField: "User-Agent") }
        if let cookies = task.cookies { request.setValue(cookies, forHTTPHeaderField: "Cookie") }

        if task.acceptRanges {
            let rangeStart = currentSegment.startByte + currentSegment.downloadedBytes
            let rangeEnd = currentSegment.endByte > 0 ? "\(currentSegment.endByte)" : ""
            request.setValue("bytes=\(rangeStart)-\(rangeEnd)", forHTTPHeaderField: "Range")
        }

        currentSegment.status = .downloading
        onSegmentUpdate(currentSegment)

        let handle = try FileHandle(forWritingTo: targetFile)
        defer { try? handle.close() }

        let targetOffset = UInt64(currentSegment.startByte + currentSegment.downloadedBytes)
        try handle.seek(toOffset: targetOffset)

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if task.acceptRanges && httpResponse.statusCode != 206 && currentSegment.downloadedBytes > 0 {
            currentSegment.downloadedBytes = 0
            try handle.seek(toOffset: UInt64(currentSegment.startByte))
        }

        // High-performance batched chunk streaming (64KB buffer)
        var buffer = Data()
        buffer.reserveCapacity(65536)
        var unrecordedBytes: Int64 = 0

        for try await byte in bytes {
            if isPaused || isCancelled {
                if !buffer.isEmpty {
                    try handle.write(contentsOf: buffer)
                    currentSegment.downloadedBytes += Int64(buffer.count)
                    unrecordedBytes += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                }
                if unrecordedBytes > 0 {
                    speedTracker.record(bytes: unrecordedBytes)
                }
                currentSegment.status = .paused
                onSegmentUpdate(currentSegment)
                return currentSegment
            }

            buffer.append(byte)

            if buffer.count >= 65536 {
                try handle.write(contentsOf: buffer)
                let count = Int64(buffer.count)
                currentSegment.downloadedBytes += count
                unrecordedBytes += count
                buffer.removeAll(keepingCapacity: true)

                // Update speed stats once every 256KB to minimize mutex contention
                if unrecordedBytes >= 262144 {
                    speedTracker.record(bytes: unrecordedBytes)
                    unrecordedBytes = 0
                    let speed = speedTracker.currentSpeed()
                    onProgress(currentSegment.downloadedBytes, speed)
                    onSegmentUpdate(currentSegment)
                }
            }
        }

        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            let count = Int64(buffer.count)
            currentSegment.downloadedBytes += count
            unrecordedBytes += count
            buffer.removeAll(keepingCapacity: true)
        }

        if unrecordedBytes > 0 {
            speedTracker.record(bytes: unrecordedBytes)
            let speed = speedTracker.currentSpeed()
            onProgress(currentSegment.downloadedBytes, speed)
        }

        currentSegment.status = .completed
        onSegmentUpdate(currentSegment)
        return currentSegment
    }

    public func pause() {
        isPaused = true
    }

    public func cancel() {
        isCancelled = true
    }
}
