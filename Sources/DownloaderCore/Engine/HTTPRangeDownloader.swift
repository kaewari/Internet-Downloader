import Foundation
import os

private let log = Logger(subsystem: "com.internet-downloader", category: "range-downloader")

public struct ProbeResult: Sendable {
    public let totalBytes: Int64
    public let acceptRanges: Bool
    public let etag: String?
    public let lastModified: String?
    public let suggestedFilename: String?
}

/// Server đổi file giữa lúc resume (412 Precondition Failed / 416 Range Not
/// Satisfiable sau khi gửi If-Range). Không retry Range cũ — caller (A-F11)
/// phải re-probe rồi rebuild segments.
public struct HTTPResourceChangedError: LocalizedError, Sendable {
    public let statusCode: Int

    public init(statusCode: Int) {
        self.statusCode = statusCode
    }

    public var errorDescription: String? {
        "Tài nguyên trên máy chủ đã thay đổi (HTTP \(statusCode)) — nhấn Tiếp tục để dò lại và tải lại"
    }
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

        do {
            let (probeOutcome, _) = try await readRangeGetProbe(getRequest, session: activeSession)
            switch probeOutcome {
            case .success(let data, let getHTTP):
                return parseHeaders(from: getHTTP, url: url, headerData: data)
            case .failure(let status, _):
                if let headProbeResult = headProbeResult {
                    return headProbeResult
                }
                throw NSError(
                    domain: "HTTPRangeDownloader",
                    code: status,
                    userInfo: [NSLocalizedDescriptionKey: "Server trả về HTTP \(status) khi dò file — kiểm tra liên kết hoặc quyền truy cập."]
                )
            }
        } catch {
            // A-F18: Range probe lỗi mà HEAD đã có kết quả → giữ HEAD;
            // không còn gì trong tay → throw để caller retry (không nuốt).
            if let headProbeResult = headProbeResult {
                log.warning("Range probe failed (\(error.localizedDescription)) — keeping HEAD result for \(url.absoluteString)")
                return headProbeResult
            }
            throw error
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

    private enum RangeProbeOutcome {
        case success(data: Data, response: HTTPURLResponse)
        case failure(status: Int, capturedData: Data?)
    }

    // Streaming Range-GET probe: đọc tối đa 512 byte đầu rồi hủy stream để
    // không nạp toàn bộ file vào RAM khi server ignore Range trả 200.
    //
    // A-F18: mọi catch đều log + throw để caller retry — không nuốt lỗi thành
    // `nil` câm (trừ lỗi đọc stream giữa chừng: giữ dữ liệu đã đọc, chỉ log).
    private static func readRangeGetProbe(_ request: URLRequest, session: URLSession) async throws -> (RangeProbeOutcome, HTTPURLResponse?) {
        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            var data = Data()
            data.reserveCapacity(512)
            do {
                for try await byte in stream {
                    data.append(byte)
                    if data.count >= 512 { break }
                }
            } catch {
                log.warning("Range-GET probe stream interrupted for \(request.url?.absoluteString ?? "?"): \(error.localizedDescription)")
            }

            if (200...299).contains(http.statusCode) {
                return (.success(data: data, response: http), http)
            }
            return (.failure(status: http.statusCode, capturedData: data), http)
        } catch {
            log.warning("Range-GET probe failed for \(request.url?.absoluteString ?? "?"): \(error.localizedDescription)")
            throw error
        }
    }

    private static func getResponseForStatus(_ status: Int, request: URLRequest) -> HTTPURLResponse {
        let best = (200...599).contains(status) ? status : 400
        return HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: best, httpVersion: nil, headerFields: [:]) ?? HTTPURLResponse()
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
        onSegmentUpdate: @escaping @Sendable (DownloadSegment) -> Void,
        onReprobe: (@Sendable (ProbeResult) -> Void)? = nil
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

        // Direct sparse file allocation on APFS: pre-allocate total size instantly.
        // Chỉ khởi tạo lúc file CHƯA tồn tại — truncate lặp lại giữa lúc các segment
        // khác đang ghi sẽ xoá mất dữ liệu. File vì đã có là checkpoint cũ (resume).
        let targetFile = task.finalFilePath
        if !fileManager.fileExists(atPath: targetFile.path) {
            if !fileManager.createFile(atPath: targetFile.path, contents: nil) {
                throw NSError(domain: "HTTPRangeDownloader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Không tạo được file đích: \(targetFile.path)"])
            }
            if task.totalBytes > 0 {
                let initHandle = try FileHandle(forWritingTo: targetFile)
                try initHandle.truncate(atOffset: UInt64(task.totalBytes))
                try initHandle.close()
            }
        }

        var updatedTask = task
        var updatedSegments = segments
        if updatedSegments.isEmpty {
            updatedSegments = Self.calculateSegments(
                taskId: task.id,
                totalBytes: task.totalBytes,
                segmentCount: 1,
                acceptRanges: task.acceptRanges
            )
        }

        // A-F11: resource đổi giữa chừng (412/416 sau If-Range) → re-probe rồi
        // rebuild segments đúng 1 lần, sau đó chạy lại từ đầu trên file mới.
        var didReprobe = false
        while true {
            do {
                try await runSegments(
                    task: updatedTask,
                    segments: updatedSegments,
                    targetFile: targetFile,
                    onProgress: onProgress,
                    onSegmentUpdate: onSegmentUpdate
                )
                return
            } catch let stale as HTTPResourceChangedError where !didReprobe {
                if Task.isCancelled { throw CancellationError() }
                didReprobe = true
                log.warning("Resource changed mid-download (HTTP \(stale.statusCode)) — re-probing \(updatedTask.url.absoluteString)")
                let probe = try await Self.probeURL(
                    url: updatedTask.url,
                    customHeaders: updatedTask.headers,
                    cookies: updatedTask.cookies,
                    userAgent: updatedTask.userAgent
                )
                let unchanged = probe.totalBytes == updatedTask.totalBytes
                    && probe.acceptRanges == updatedTask.acceptRanges
                    && (probe.etag ?? "") == (updatedTask.etag ?? "")
                if unchanged {
                    // Kích thước/etag không đổi — Range cũ vẫn đúng, lỗi không
                    // phải do resource đổi → ném lại lỗi gốc.
                    throw stale
                }
                updatedTask.totalBytes = probe.totalBytes
                updatedTask.acceptRanges = probe.acceptRanges
                updatedTask.etag = probe.etag
                updatedTask.lastModified = probe.lastModified
                try Self.resizeTargetFile(at: targetFile, to: probe.totalBytes)
                updatedSegments = Self.calculateSegments(
                    taskId: updatedTask.id,
                    totalBytes: probe.totalBytes,
                    segmentCount: max(1, updatedSegments.count),
                    acceptRanges: probe.acceptRanges
                )
                // Báo cho DownloadManager đồng bộ DB (totalBytes/etag/segments).
                onReprobe?(probe)
            }
        }
    }

    /// Đổi kích thước file đích sau re-probe: resource mới thay hoàn toàn
    /// resource cũ nên truncate/xoá để ghi lại từ đầu (không giữ byte cũ).
    private static func resizeTargetFile(at targetFile: URL, to totalBytes: Int64) throws {
        let fileManager = FileManager.default
        if totalBytes > 0 {
            if !fileManager.fileExists(atPath: targetFile.path) {
                fileManager.createFile(atPath: targetFile.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: targetFile)
            try handle.truncate(atOffset: UInt64(totalBytes))
            try handle.close()
        } else {
            try? fileManager.removeItem(at: targetFile)
            fileManager.createFile(atPath: targetFile.path, contents: nil)
        }
    }

    /// Chạy toàn bộ segments qua task group (tách khỏi `download` để vòng
    /// re-probe A-F11 có thể gọi lại với segments đã rebuild).
    private func runSegments(
        task: DownloadTask,
        segments: [DownloadSegment],
        targetFile: URL,
        onProgress: @escaping @Sendable (Int64, Double) -> Void,
        onSegmentUpdate: @escaping @Sendable (DownloadSegment) -> Void
    ) async throws {
        var updatedSegments = segments
        let coordinator = HTTPDownloadProgressCoordinator(
            segments: updatedSegments,
            onProgress: onProgress,
            onSegmentUpdate: onSegmentUpdate
        )

        try await withThrowingTaskGroup(of: DownloadSegment.self) { group in
            for segment in updatedSegments {
                group.addTask { [self] in
                    try await self.downloadSegmentWithRetry(
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

        if isPaused || isCancelled || Task.isCancelled {
            throw CancellationError()
        }

        // Clean up temporary checkpoint directory if any
        try? FileManager.default.removeItem(at: task.tempDirectory)
    }

    private func downloadSegmentWithRetry(
        segment: DownloadSegment,
        task: DownloadTask,
        targetFile: URL,
        coordinator: HTTPDownloadProgressCoordinator
    ) async throws -> DownloadSegment {
        var currentSegment = segment
        var attempt = 0
        while true {
            do {
                return try await downloadSegmentDirect(
                    segment: currentSegment,
                    task: task,
                    targetFile: targetFile,
                    coordinator: coordinator
                )
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw error
                }
                // A-F10: gộp điều kiện vào shouldRetry — không còn `-1` thủ công.
                // HTTPResourceChangedError (412/416) không retry ở đây mà xử lý
                // ở vòng re-probe của `download` (isRetryable == false).
                guard RetryPolicy.shouldRetry(failedAttempt: attempt, error: error) else {
                    throw error
                }
                // Tôn trọng header Retry-After nếu server gửi kèm.
                let retryAfter = (error as NSError).userInfo["retryAfter"] as? String
                let delay = RetryPolicy.retryDelay(attempt: attempt, retryAfterHeader: retryAfter) ?? 1.0
                attempt += 1
                log.warning("Segment \(currentSegment.index) failed (\(error.localizedDescription)), retrying attempt \(attempt)/\(RetryPolicy.maxAttempts) after \(delay)s")
                currentSegment.downloadedBytes = min(currentSegment.downloadedBytes, currentSegment.expectedBytes > 0 ? currentSegment.expectedBytes : currentSegment.downloadedBytes)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { throw CancellationError() }
            }
        }
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

        // A-F7: resume gửi điều kiện tiền đề để phát hiện file đổi giữa chừng:
        // ưu tiên If-Range(etag), fallback If-Unmodified-Since(lastModified).
        // Chỉ gửi khi resume (đã có byte) — tải mới không cần.
        if currentSegment.downloadedBytes > 0 {
            if let etag = task.etag, !etag.isEmpty {
                request.setValue(etag, forHTTPHeaderField: "If-Range")
            } else if let lastModified = task.lastModified, !lastModified.isEmpty {
                request.setValue(lastModified, forHTTPHeaderField: "If-Unmodified-Since")
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
            // A-F7/A-F11: 412 (If-Range fail) / 416 (Range không thỏa — file đã
            // đổi/khác kích thước) → throw riêng để caller re-probe + rebuild
            // segments, không retry Range cũ và không gộp lỗi 4xx chung.
            if httpResponse.statusCode == 412 || httpResponse.statusCode == 416 {
                throw HTTPResourceChangedError(statusCode: httpResponse.statusCode)
            }
            let msg = "Server returned HTTP \(httpResponse.statusCode) (\(HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)))"
            throw NSError(
                domain: "HTTPRangeDownloader",
                code: httpResponse.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey: msg,
                    // Giữ header Retry-After để lần retry dùng đúng thời gian chờ.
                    "retryAfter": httpResponse.value(forHTTPHeaderField: "Retry-After") ?? ""
                ]
            )
        }

        // Chỉ coi là lỗi khi tệp đích KHÔNG phải HTML (tải file .html là hợp lệ).
        let responseIsHTML = httpResponse.mimeType?.lowercased().contains("html") ?? false
        if responseIsHTML, !Self.isHTMLFileName(task.filename) {
            throw NSError(domain: "HTTPRangeDownloader", code: 415, userInfo: [NSLocalizedDescriptionKey: "Nguồn trả HTML thay vì file"])
        }

        // Server trả 200 toàn bộ (bỏ qua Range): bỏ qua startByte byte đầu
        // của body để chỉ ghi phần thuộc cửa sổ segment này.
        var discardLeadingBytes: Int64 = 0

        if task.acceptRanges && httpResponse.statusCode != 206 {
            // Server quảng cáo Accept-Ranges nhưng bỏ qua Range, trả 200 toàn bộ
            // body — reset segment và bỏ qua startByte byte đầu để ghi đúng
            // cửa sổ của segment (nếu ghi thẳng sẽ lệch vị trí dữ liệu).
            currentSegment.downloadedBytes = 0
            try handle.seek(toOffset: UInt64(currentSegment.startByte))
            discardLeadingBytes = currentSegment.startByte
        }

        // High-performance batched chunk streaming (64KB buffer)
        var buffer = Data()
        buffer.reserveCapacity(65536)
        var unrecordedBytes: Int64 = 0

        let segmentEndByte: Int64 = currentSegment.endByte
        // Clamp write vào khoảng của segment (endByte INCLUSIVE: room = end - start + 1);
        // server có thể gửi dư (200 full body) hoặc nhiều hơn Range xin.
        // Trả về true nghĩa là server còn gửi thêm byte ngoài cửa sổ segment.
        let writeClamped = { () throws -> Bool in
            var room = Int64.max
            if segmentEndByte >= 0 {
                room = segmentEndByte - currentSegment.startByte + 1 - currentSegment.downloadedBytes
            }
            let available = Int64(buffer.count)
            let keep = min(available, max(0, room))
            if keep > 0 {
                try handle.write(contentsOf: buffer.prefix(Int(keep)))
                currentSegment.downloadedBytes += keep
                unrecordedBytes += keep
            }
            let overflow = keep < available
            buffer.removeAll(keepingCapacity: true)
            return overflow
        }

        let flushAndPauseSegment = { () throws -> DownloadSegment in
            if !buffer.isEmpty {
                _ = try writeClamped()
            }
            if unrecordedBytes > 0 {
                self.speedTracker.record(bytes: unrecordedBytes)
                unrecordedBytes = 0
            }
            coordinator.markSegmentPaused(segment: currentSegment)
            return currentSegment
        }

        do {
            for try await byte in bytes {
                if isPaused || isCancelled || Task.isCancelled {
                    return try flushAndPauseSegment()
                }

                if discardLeadingBytes > 0 {
                    discardLeadingBytes -= 1
                    continue
                }

                buffer.append(byte)

                if currentSegment.startByte == 0 && currentSegment.downloadedBytes == 0 && buffer.count == 512 {
                    let prefix = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if Self.looksLikeHTML(prefix), !Self.isHTMLFileName(task.filename) {
                        throw NSError(domain: "HTTPRangeDownloader", code: 415, userInfo: [NSLocalizedDescriptionKey: "Nguồn trả HTML thay vì file (có thể trang login/captcha)"])
                    }
                }
                if buffer.count >= 65536 {
                    _ = try writeClamped()

                    if currentSegment.endByte >= 0 && currentSegment.startByte + currentSegment.downloadedBytes > currentSegment.endByte {
                        // Đã đủ byte của segment — bỏ byte dư server gửi thêm
                        break
                    }

                    // Update speed stats once every 256KB to minimize mutex contention
                    if unrecordedBytes >= 262144 {
                        speedTracker.record(bytes: unrecordedBytes)
                        unrecordedBytes = 0
                        let speed = speedTracker.currentSpeed()
                        coordinator.recordProgress(segment: currentSegment, speed: speed)
                    }
                }
            }
        } catch {
            if isPaused || isCancelled || Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                _ = try? flushAndPauseSegment()
                throw CancellationError()
            }
            throw error
        }

        if isPaused || isCancelled || Task.isCancelled {
            return try flushAndPauseSegment()
        }

        if !buffer.isEmpty {
            // HTML ngắn (<512) tới tận final flush — vẫn phải bắt, trừ khi tệp đích
            // là HTML/XHTML (tải trang web là hợp lệ).
            if currentSegment.startByte == 0 && currentSegment.downloadedBytes == 0 {
                let prefix = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if Self.looksLikeHTML(prefix), !Self.isHTMLFileName(task.filename) {
                    throw NSError(domain: "HTTPRangeDownloader", code: 415, userInfo: [NSLocalizedDescriptionKey: "Nguồn trả HTML thay vì file (có thể trang login/captcha)"])
                }
            }
            _ = try writeClamped()
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

    // MARK: - Helpers

    /// Body bắt đầu bằng thẻ HTML → nhiều khả năng server trả về trang login/captcha.
    static func looksLikeHTML(_ prefix: String) -> Bool {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        return lowered.hasPrefix("<!doctype html") || lowered.hasPrefix("<html")
    }

    /// Tệp đích cố ý là HTML/XHTML → nội dung HTML là hợp lệ, không phải lỗi.
    static func isHTMLFileName(_ filename: String) -> Bool {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        return ext == "html" || ext == "htm" || ext == "xhtml"
    }
}
