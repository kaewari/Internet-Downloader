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
    private var activeTasks: [Task<Void, Error>] = []

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public static func probeURL(
        url: URL,
        customHeaders: [String: String]? = nil,
        cookies: String? = nil,
        userAgent: String? = nil,
        session: URLSession = .shared
    ) async throws -> ProbeResult {
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

        let (_, response) = try await session.data(for: request)
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

            let (_, getResponse) = try await session.data(for: getRequest)
            if let getHTTP = getResponse as? HTTPURLResponse {
                return parseHeaders(from: getHTTP, url: url)
            }
        }

        return parseHeaders(from: httpResponse, url: url)
    }

    private static func parseHeaders(from response: HTTPURLResponse, url: URL) -> ProbeResult {
        let headers = response.allHeaderFields

        // Check accept ranges
        var acceptRanges = false
        if let accept = headers["Accept-Ranges"] as? String, accept.lowercased().contains("bytes") {
            acceptRanges = true
        } else if response.statusCode == 206 {
            acceptRanges = true
        }

        // Check Content-Range for total length if 206
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
        let tempDir = task.tempDirectory
        if !fileManager.fileExists(atPath: tempDir.path) {
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        }

        var updatedSegments = segments

        try await withThrowingTaskGroup(of: DownloadSegment.self) { group in
            for segment in updatedSegments {
                group.addTask { [self] in
                    try await self.downloadSegment(
                        segment: segment,
                        task: task,
                        tempDir: tempDir,
                        onProgress: onProgress,
                        onSegmentUpdate: onSegmentUpdate
                    )
                }
            }

            var results: [DownloadSegment] = []
            for try await completedSeg in group {
                results.append(completedSeg)
                if let idx = updatedSegments.firstIndex(where: { $0.id == completedSeg.id }) {
                    updatedSegments[idx] = completedSeg
                }
            }

            // Assemble file
            let assembler = FileAssembler()
            try assembler.assemble(
                segments: results,
                tempDirectory: tempDir,
                destinationFile: task.finalFilePath,
                expectedTotalBytes: task.totalBytes
            )
        }
    }

    private func downloadSegment(
        segment: DownloadSegment,
        task: DownloadTask,
        tempDir: URL,
        onProgress: @escaping @Sendable (Int64, Double) -> Void,
        onSegmentUpdate: @escaping @Sendable (DownloadSegment) -> Void
    ) async throws -> DownloadSegment {
        var currentSegment = segment
        let partFile = currentSegment.tempFile(in: tempDir)
        let fileManager = FileManager.default

        // Check existing file part for resume
        var existingBytes: Int64 = 0
        if fileManager.fileExists(atPath: partFile.path) {
            let attrs = try fileManager.attributesOfItem(atPath: partFile.path)
            existingBytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        } else {
            fileManager.createFile(atPath: partFile.path, contents: nil)
        }
        currentSegment.downloadedBytes = existingBytes

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

        let handle = try FileHandle(forWritingTo: partFile)
        defer { try? handle.close() }
        try handle.seekToEnd()

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if task.acceptRanges && httpResponse.statusCode != 206 && currentSegment.downloadedBytes > 0 {
            // Server did not honor range for resume, restart segment
            try handle.truncate(atOffset: 0)
            currentSegment.downloadedBytes = 0
        }

        var buffer = Data()
        buffer.reserveCapacity(65536)

        for try await byte in bytes {
            if isPaused || isCancelled {
                if !buffer.isEmpty {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
                currentSegment.status = .paused
                onSegmentUpdate(currentSegment)
                return currentSegment
            }

            buffer.append(byte)
            currentSegment.downloadedBytes += 1
            speedTracker.record(bytes: 1)

            if buffer.count >= 65536 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                let speed = speedTracker.currentSpeed()
                onProgress(currentSegment.downloadedBytes, speed)
                onSegmentUpdate(currentSegment)
            }
        }

        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
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
