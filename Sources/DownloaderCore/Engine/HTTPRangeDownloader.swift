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

public final class HTTPDownloadProgressCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var segments: [UUID: DownloadSegment]
    private var totalDownloadedBytes: Int64
    private let onProgress: @Sendable (Int64, Double) -> Void
    private let onSegmentUpdate: @Sendable (DownloadSegment) -> Void

    public init(
        segments: [DownloadSegment],
        onProgress: @escaping @Sendable (Int64, Double) -> Void,
        onSegmentUpdate: @escaping @Sendable (DownloadSegment) -> Void
    ) {
        var map: [UUID: DownloadSegment] = [:]
        var initialTotal: Int64 = 0
        for seg in segments {
            map[seg.id] = seg
            initialTotal += seg.downloadedBytes
        }
        self.segments = map
        self.totalDownloadedBytes = initialTotal
        self.onProgress = onProgress
        self.onSegmentUpdate = onSegmentUpdate
    }

    public func recordProgress(segment: DownloadSegment, speed: Double) {
        lock.lock()
        defer { lock.unlock() }
        segments[segment.id] = segment
        let computedTotal = segments.values.reduce(Int64(0)) { $0 + $1.downloadedBytes }
        if computedTotal > totalDownloadedBytes {
            totalDownloadedBytes = computedTotal
        }
        let currentTotal = totalDownloadedBytes
        onProgress(currentTotal, speed)
        onSegmentUpdate(segment)
    }

    public func markSegmentCompleted(segment: DownloadSegment, speed: Double) {
        var updated = segment
        updated.status = .completed
        recordProgress(segment: updated, speed: speed)
    }

    public func markSegmentPaused(segment: DownloadSegment) {
        var updated = segment
        updated.status = .paused
        lock.lock()
        defer { lock.unlock() }
        segments[segment.id] = updated
        onSegmentUpdate(updated)
    }

    public func currentTotal() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return totalDownloadedBytes
    }

    public func currentSegments() -> [DownloadSegment] {
        lock.lock()
        defer { lock.unlock() }
        return Array(segments.values.sorted(by: { $0.index < $1.index }))
    }
}

public actor HTTPRangeDownloader {
    private let session: URLSession
    private let speedTracker = SpeedTracker()
    private var isPaused = false
    private var isCancelled = false

    public static func makeOptimizedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpMaximumConnectionsPerHost = 32
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 86400
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: HTTPRedirectPolicy(), delegateQueue: nil)
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
        if DataURLHandler.isDataURL(url) {
            let res = try DataURLHandler.parse(urlString: url.absoluteString)
            return ProbeResult(
                totalBytes: Int64(res.data.count),
                acceptRanges: false,
                etag: nil,
                lastModified: nil,
                suggestedFilename: "data_file.\(res.suggestedExtension)"
            )
        }

        guard URLNormalizer.normalize(url.absoluteString) != nil else { throw URLError(.badURL) }
        let activeSession = session ?? makeOptimizedSession()
        defer { if session == nil { activeSession.invalidateAndCancel() } }
        let effectiveUA = userAgent ?? URLNormalizer.defaultUserAgent
        let defaultRef = customHeaders?["Referer"] ?? (url.host.map { "https://\($0)/" } ?? url.absoluteString)

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue(effectiveUA, forHTTPHeaderField: "User-Agent")
        request.setValue(defaultRef, forHTTPHeaderField: "Referer")

        if let headers = customHeaders {
            for (key, val) in headers { request.setValue(val, forHTTPHeaderField: key) }
        }
        if let cookies = cookies, !cookies.isEmpty {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }

        // 1. Try HEAD request
        var probeResponse: HTTPURLResponse?
        var headProbeResult: ProbeResult?
        if let (_, response) = try? await activeSession.data(for: request),
           let httpResponse = response as? HTTPURLResponse {
            if (200...299).contains(httpResponse.statusCode) {
                let parsed = parseHeaders(from: httpResponse, url: url)
                if let name = parsed.suggestedFilename, !(name as NSString).pathExtension.isEmpty {
                    return parsed
                }
                headProbeResult = parsed
            }
            probeResponse = httpResponse
        }

        // If HEAD failed with 403 and defaultRef is cross-origin, retry with same-origin referer
        if probeResponse?.statusCode == 403, let host = url.host, !defaultRef.contains(host) {
            var retryReq = request
            retryReq.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
            if let (_, retryResp) = try? await activeSession.data(for: retryReq),
               let retryHTTP = retryResp as? HTTPURLResponse,
               (200...299).contains(retryHTTP.statusCode) {
                let parsed = parseHeaders(from: retryHTTP, url: url)
                if let name = parsed.suggestedFilename, !(name as NSString).pathExtension.isEmpty {
                    return parsed
                }
                headProbeResult = parsed
            }
        }

        // 2. Fallback to Range 0-511 GET probe (also resolves magic bytes when extension is missing)
        var getRequest = URLRequest(url: url)
        getRequest.httpMethod = "GET"
        getRequest.setValue("bytes=0-511", forHTTPHeaderField: "Range")
        getRequest.setValue(effectiveUA, forHTTPHeaderField: "User-Agent")
        getRequest.setValue(defaultRef, forHTTPHeaderField: "Referer")

        if let headers = customHeaders {
            for (key, val) in headers { getRequest.setValue(val, forHTTPHeaderField: key) }
        }
        if let cookies = cookies, !cookies.isEmpty {
            getRequest.setValue(cookies, forHTTPHeaderField: "Cookie")
        }

        if let (getData, getResponse) = try? await activeSession.data(for: getRequest),
           let getHTTP = getResponse as? HTTPURLResponse,
           (200...299).contains(getHTTP.statusCode) {
            return parseHeaders(from: getHTTP, url: url, headerData: getData.prefix(512))
        }

        if let headProbeResult = headProbeResult {
            return headProbeResult
        }

        // 3. Fallback: Return basic probe allowing direct single-stream GET
        var fallbackName = FileTypeDetector.extractFilename(from: url)
        if fallbackName == nil || fallbackName?.isEmpty == true {
            let last = url.lastPathComponent
            fallbackName = last.isEmpty ? "download" : last
        }
        return ProbeResult(
            totalBytes: -1,
            acceptRanges: false,
            etag: nil,
            lastModified: nil,
            suggestedFilename: fallbackName
        )
    }

    private static func parseHeaders(from response: HTTPURLResponse, url: URL, headerData: Data? = nil) -> ProbeResult {
        var acceptRanges = false
        if let accept = response.value(forHTTPHeaderField: "Accept-Ranges"), accept.lowercased().contains("bytes") {
            acceptRanges = true
        } else if response.statusCode == 206 {
            acceptRanges = true
        }

        var totalBytes: Int64 = response.expectedContentLength
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range") {
            acceptRanges = true
            let parts = contentRange.split(separator: "/")
            if parts.count == 2, let parsed = Int64(parts[1]) {
                totalBytes = parsed
            }
        } else if totalBytes <= 0, let lenStr = response.value(forHTTPHeaderField: "Content-Length"), let parsed = Int64(lenStr) {
            totalBytes = parsed
        }

        let etag = response.value(forHTTPHeaderField: "ETag")
        let lastModified = response.value(forHTTPHeaderField: "Last-Modified")

        // 1. Check Content-Disposition (case-insensitive)
        var suggestedFilename: String?
        if let disposition = response.value(forHTTPHeaderField: "Content-Disposition") {
            suggestedFilename = FileTypeDetector.parseFilename(from: disposition)
        }

        // 2. Check query parameters of redirected URL or original URL (rscd, response-content-disposition, filename)
        if suggestedFilename == nil || FileTypeDetector.isOpaqueIdentifier(suggestedFilename!) {
            if let redirectedURL = response.url, let queryName = FileTypeDetector.extractFilename(from: redirectedURL) {
                suggestedFilename = queryName
            } else if let queryName = FileTypeDetector.extractFilename(from: url) {
                suggestedFilename = queryName
            }
        }

        // 3. Fallback to path component
        if suggestedFilename == nil || suggestedFilename?.isEmpty == true {
            let redirectedPath = response.url?.lastPathComponent ?? ""
            if !redirectedPath.isEmpty && redirectedPath != "/" && !FileTypeDetector.isOpaqueIdentifier(redirectedPath) {
                suggestedFilename = redirectedPath
            } else {
                let last = url.lastPathComponent
                suggestedFilename = last.isEmpty ? "download" : last
            }
        }

        // 4. If filename has no extension or is generic, infer extension from Content-Type or Magic Bytes
        if let current = suggestedFilename, (current as NSString).pathExtension.isEmpty {
            if let mime = response.value(forHTTPHeaderField: "Content-Type"),
               let ext = FileTypeDetector.fileExtension(forMIMEType: mime) {
                suggestedFilename = "\(current).\(ext)"
            } else if let data = headerData,
                      let magicExt = FileTypeDetector.detectExtension(fromHeaderData: data) {
                suggestedFilename = "\(current).\(magicExt)"
            }
        }

        return ProbeResult(
            totalBytes: totalBytes,
            acceptRanges: acceptRanges,
            etag: etag,
            lastModified: lastModified,
            suggestedFilename: suggestedFilename
        )
    }

    public static func parseFilename(from contentDisposition: String) -> String? {
        FileTypeDetector.parseFilename(from: contentDisposition)
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

        // Handle Data URLs directly without network
        if DataURLHandler.isDataURL(task.url) {
            let res = try DataURLHandler.parse(urlString: task.url.absoluteString)
            let destDir = task.destinationFolder
            if !fileManager.fileExists(atPath: destDir.path) {
                try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
            }
            try res.data.write(to: task.finalFilePath)
            onProgress(Int64(res.data.count), 0)
            return
        }

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
        if updatedSegments.isEmpty {
            updatedSegments = Self.calculateSegments(
                taskId: task.id,
                totalBytes: task.totalBytes,
                segmentCount: 1,
                acceptRanges: task.acceptRanges
            )
        }

        let coordinator = HTTPDownloadProgressCoordinator(
            segments: updatedSegments,
            onProgress: onProgress,
            onSegmentUpdate: onSegmentUpdate
        )

        try await withThrowingTaskGroup(of: DownloadSegment.self) { group in
            for segment in updatedSegments {
                group.addTask { [self] in
                    try await self.downloadSegmentDirect(
                        segment: segment,
                        task: task,
                        targetFile: targetFile,
                        coordinator: coordinator
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
        coordinator: HTTPDownloadProgressCoordinator
    ) async throws -> DownloadSegment {
        var currentSegment = segment

        if currentSegment.expectedBytes > 0 && currentSegment.downloadedBytes >= currentSegment.expectedBytes {
            currentSegment.status = .completed
            coordinator.recordProgress(segment: currentSegment, speed: 0)
            return currentSegment
        }

        guard URLNormalizer.normalize(task.url.absoluteString) != nil else { throw URLError(.badURL) }
        var request = URLRequest(url: task.url)
        request.httpMethod = "GET"
        let effectiveUA = task.userAgent ?? URLNormalizer.defaultUserAgent
        request.setValue(effectiveUA, forHTTPHeaderField: "User-Agent")
        let effectiveRef = task.referrer ?? (task.url.host.map { "https://\($0)/" } ?? task.url.absoluteString)
        request.setValue(effectiveRef, forHTTPHeaderField: "Referer")
        if let cookies = task.cookies { request.setValue(cookies, forHTTPHeaderField: "Cookie") }
        if let headers = task.headers {
            for (key, val) in headers {
                request.setValue(val, forHTTPHeaderField: key)
            }
        }

        if task.acceptRanges {
            let rangeStart = currentSegment.startByte + currentSegment.downloadedBytes
            let rangeEnd = currentSegment.endByte > 0 ? "\(currentSegment.endByte)" : ""
            request.setValue("bytes=\(rangeStart)-\(rangeEnd)", forHTTPHeaderField: "Range")
        }

        currentSegment.status = .downloading
        coordinator.recordProgress(segment: currentSegment, speed: 0)

        let handle = try FileHandle(forWritingTo: targetFile)
        defer { try? handle.close() }

        let targetOffset = UInt64(currentSegment.startByte + currentSegment.downloadedBytes)
        try handle.seek(toOffset: targetOffset)

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let msg = "Server returned HTTP \(httpResponse.statusCode) (\(HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)))"
            throw NSError(domain: "HTTPRangeDownloader", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        let expectsMedia = ["mp4","mkv","mov","avi","webm","mp3","m4a","flac","wav","aac","ogg","ts"].contains(URL(fileURLWithPath: task.filename).pathExtension.lowercased())
        if expectsMedia && (httpResponse.mimeType?.lowercased().contains("html") ?? false) {
            throw NSError(domain: "HTTPRangeDownloader", code: 415, userInfo: [NSLocalizedDescriptionKey: "Nguồn trả HTML thay vì media"])
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
                coordinator.markSegmentPaused(segment: currentSegment)
                return currentSegment
            }

            buffer.append(byte)

            if expectsMedia && currentSegment.startByte == 0 && currentSegment.downloadedBytes == 0 && buffer.count == 512 {
                let prefix = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html") { throw URLError(.cannotDecodeContentData) }
            }
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
                    coordinator.recordProgress(segment: currentSegment, speed: speed)
                }
            }
        }

        if !buffer.isEmpty {
            if expectsMedia && currentSegment.startByte == 0 && currentSegment.downloadedBytes == 0 {
                let prefix = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html") { throw URLError(.cannotDecodeContentData) }
            }
            try handle.write(contentsOf: buffer)
            let count = Int64(buffer.count)
            currentSegment.downloadedBytes += count
            unrecordedBytes += count
            buffer.removeAll(keepingCapacity: true)
        }

        if unrecordedBytes > 0 {
            speedTracker.record(bytes: unrecordedBytes)
        }
        let speed = speedTracker.currentSpeed()
        currentSegment.status = .completed
        coordinator.recordProgress(segment: currentSegment, speed: speed)
        return currentSegment
    }

    public func pause() {
        isPaused = true
    }

    public func cancel() {
        isCancelled = true
    }
}
