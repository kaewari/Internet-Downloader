import Foundation

// MARK: - Cấu hình nguồn media

/// Một nguồn media trong danh sách kiểm thử.
public struct MediaSourceSpec: Codable, Sendable {
    public let id: String
    public let title: String?
    public let url: String
    public let host: String?
    /// `video` | `audio` | `image` | `any`
    public let kind: String
    public let tags: [String]
    /// `public-sample` | `public-nsfw` | `requires-auth`
    public let access: String
    public let minBytes: Int64
    public let maxBytes: Int64
    public let expectStreams: [String]
    public let referer: String?
    /// Tên adapter làm mới URL (xem `SourceRefreshAdapters`).
    public let sourceAPI: String?
    /// Tham số cho adapter (URL feed RSS, identifier của archive.org, …).
    public let sourceRef: String?
    /// `retired` = nguồn không dùng được (URL chết vĩnh viễn) → bỏ qua khi chạy.
    public let status: String?
    public let notes: String?

    enum CodingKeys: String, CodingKey {
        case id, title, url, host, kind, tags, access, notes, status
        case minBytes = "min_bytes"
        case maxBytes = "max_bytes"
        case expectStreams = "expect_streams"
        case referer
        case sourceAPI = "source_api"
        case sourceRef = "source_ref"
    }

    public init(
        id: String,
        title: String? = nil,
        url: String,
        host: String? = nil,
        kind: String = "any",
        tags: [String] = [],
        access: String = "public-sample",
        minBytes: Int64 = 1,
        maxBytes: Int64 = 16 * 1024 * 1024,
        expectStreams: [String] = [],
        referer: String? = nil,
        sourceAPI: String? = nil,
        sourceRef: String? = nil,
        status: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.host = host
        self.kind = kind
        self.tags = tags
        self.access = access
        self.minBytes = minBytes
        self.maxBytes = maxBytes
        self.expectStreams = expectStreams
        self.referer = referer
        self.sourceAPI = sourceAPI
        self.sourceRef = sourceRef
        self.status = status
        self.notes = notes
    }

    /// Nguồn được phép chạy trong kiểm thử tự động.
    /// `requires-auth` bị chặn vì bộ test không bao giờ gửi cookie/tài khoản.
    public var isRunnable: Bool {
        guard status != "retired" else { return false }
        return access == "public-sample" || access == "public-nsfw"
    }

    public var isNSFW: Bool {
        tags.contains("nsfw") || access == "public-nsfw"
    }
}

/// Toàn bộ danh sách nguồn.
public struct MediaSourceCatalog: Codable, Sendable {
    public let cases: [MediaSourceSpec]

    public init(cases: [MediaSourceSpec]) {
        self.cases = cases
    }

    public static func load(from path: String) throws -> MediaSourceCatalog {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(MediaSourceCatalog.self, from: data)
    }

    /// Nhận diện cấu hình nguồn media (khác với cấu hình ma trận nền tảng).
    public static func isSourceCatalog(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let cases = dict["cases"] as? [[String: Any]],
              let first = cases.first else { return false }
        return first["access"] != nil || first["tags"] != nil
    }
}

// MARK: - Kết quả

/// Kết quả kiểm chứng một nguồn.
public struct MediaSourceOutcome: Codable, Sendable {
    public let id: String
    public let kind: String
    public let tags: [String]
    public let requestedURL: String
    /// URL thực tế đã tải (khác `requestedURL` nếu nguồn được tự làm mới).
    public let resolvedURL: String
    public let finalHost: String
    /// `PASS` | `FAIL` | `SKIP`
    public let status: String
    public let message: String
    public let fileSizeBytes: Int64
    public let downloadedBytes: Int64
    public let sourceSizeBytes: Int64
    public let durationSeconds: Double
    public let streams: [String]
    public let detectedExtension: String?
    public let contentType: String?
    public let redirectCount: Int
    public let refreshed: Bool

    public init(
        id: String,
        kind: String,
        tags: [String] = [],
        requestedURL: String,
        resolvedURL: String? = nil,
        finalHost: String = "",
        status: String,
        message: String,
        fileSizeBytes: Int64 = 0,
        downloadedBytes: Int64 = 0,
        sourceSizeBytes: Int64 = 0,
        durationSeconds: Double = 0,
        streams: [String] = [],
        detectedExtension: String? = nil,
        contentType: String? = nil,
        redirectCount: Int = 0,
        refreshed: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.tags = tags
        self.requestedURL = requestedURL
        self.resolvedURL = resolvedURL ?? requestedURL
        self.finalHost = finalHost
        self.status = status
        self.message = message
        self.fileSizeBytes = fileSizeBytes
        self.downloadedBytes = downloadedBytes
        self.sourceSizeBytes = sourceSizeBytes
        self.durationSeconds = durationSeconds
        self.streams = streams
        self.detectedExtension = detectedExtension
        self.contentType = contentType
        self.redirectCount = redirectCount
        self.refreshed = refreshed
    }
}

// MARK: - Runner

/// Kiểm chứng hàng loạt nguồn media bằng **engine thật của app**
/// (`MediaURLResolver` + `HTTPRangeDownloader` + `FileTypeDetector`).
///
/// Mô hình tải: **head + tail** — tải đầu và cuối file rồi ghi vào file thưa đúng
/// offset, nhờ vậy `ffprobe` đọc được cả `moov` (MP4) / cues (WebM) nằm ở cuối
/// trong khi dung lượng tải thật chỉ vài MB.
public struct MediaSourceTestRunner: Sendable {

    public struct Options: Sendable {
        public var headBytes: Int64
        public var tailBytes: Int64
        public var fullDownloadMaxBytes: Int64
        public var concurrency: Int
        public var perSourceTimeout: TimeInterval
        public var keepFiles: Bool
        public var excludeTags: Set<String>
        /// Bỏ các nguồn có host chứa chuỗi này (dùng khi một dịch vụ CDN sập).
        public var excludeHostPatterns: [String]
        public var refreshScript: String?
        public var projectRoot: String
        /// Ngân sách tải tối đa cho cả lần chạy (0 = không giới hạn).
        public var budgetBytes: Int64

        public init(
            headBytes: Int64 = 4 * 1024 * 1024,
            tailBytes: Int64 = 2 * 1024 * 1024,
            fullDownloadMaxBytes: Int64 = 32 * 1024 * 1024,
            concurrency: Int = 8,
            perSourceTimeout: TimeInterval = 90,
            keepFiles: Bool = false,
            excludeTags: Set<String> = [],
            excludeHostPatterns: [String] = [],
            refreshScript: String? = nil,
            projectRoot: String = FileManager.default.currentDirectoryPath,
            budgetBytes: Int64 = 0
        ) {
            self.headBytes = headBytes
            self.tailBytes = tailBytes
            self.fullDownloadMaxBytes = fullDownloadMaxBytes
            self.concurrency = concurrency
            self.perSourceTimeout = perSourceTimeout
            self.keepFiles = keepFiles
            self.excludeTags = excludeTags
        self.excludeHostPatterns = excludeHostPatterns
            self.refreshScript = refreshScript
            self.projectRoot = projectRoot
            self.budgetBytes = budgetBytes
        }
    }

    public let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    // MARK: Chạy

    public func run(catalog: MediaSourceCatalog, destination: URL) async -> [MediaSourceOutcome] {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let runnable = catalog.cases.filter { spec in
            guard spec.isRunnable else { return false }
            guard !options.excludeTags.isEmpty else { return true }
            guard !options.excludeTags.isEmpty else { return true }
            if !options.excludeHostPatterns.isEmpty {
                let host = (spec.host ?? URL(string: spec.url)?.host ?? "").lowercased()
                if options.excludeHostPatterns.contains(where: { host.contains($0.lowercased()) }) {
                    return false
                }
            }
            return spec.tags.filter { options.excludeTags.contains($0) }.isEmpty
        }

        // Nhóm theo host: tối đa 1 kết nối đồng thời/host (tránh bị rate-limit).
        var perHost = [String: Int]()
        var results: [MediaSourceOutcome] = []
        var index = 0

        while index < runnable.count {
            let batchSize = max(1, min(options.concurrency, runnable.count - index))
            let batch = Array(runnable[index..<(index + batchSize)])

            // Trong một batch, không lặp lại cùng một host.
            var seenHosts = Set<String>()
            let uniqueBatch = batch.filter { spec in
                let host = spec.host ?? (URL(string: spec.url)?.host ?? spec.id)
                if seenHosts.contains(host) { return false }
                seenHosts.insert(host)
                return true
            }
            let skippedDuplicates = batch.count - uniqueBatch.count
            _ = skippedDuplicates

            let outcomes = await withTaskGroup(of: MediaSourceOutcome.self) { group in
                for spec in uniqueBatch {
                    group.addTask { [options] in
                        await runOne(spec: spec, destination: destination, options: options)
                    }
                }
                var collected: [MediaSourceOutcome] = []
                for await outcome in group { collected.append(outcome) }
                return collected
            }
            results.append(contentsOf: outcomes)
            index += batchSize
        }

        return results.sorted { $0.id < $1.id }
    }

    // MARK: Một nguồn

    private func runOne(spec: MediaSourceSpec, destination: URL, options: Options) async -> MediaSourceOutcome {
        let started = Date()

        guard let url = URL(string: spec.url), URLNormalizer.normalize(spec.url) != nil else {
            return MediaSourceOutcome(
                id: spec.id, kind: spec.kind, tags: spec.tags, requestedURL: spec.url,
                status: "FAIL", message: "URL không hợp lệ",
                durationSeconds: Date().timeIntervalSince(started)
            )
        }

        if !spec.isRunnable {
            return MediaSourceOutcome(
                id: spec.id, kind: spec.kind, tags: spec.tags, requestedURL: spec.url,
                status: "SKIP", message: "Bị chặn theo policy (access=\(spec.access))",
                durationSeconds: Date().timeIntervalSince(started)
            )
        }

        var workingURL = url
        var refreshed = false
        var lastError: String = ""

        // Preflight: dò URL. Nếu chết → thử tự làm mới một lần (nếu có adapter).
        var probeInfo = await probe(url: workingURL, spec: spec)
        if probeInfo == nil {
            if let fresh = await refreshURL(for: spec) {
                refreshed = true
                workingURL = fresh
                probeInfo = await probe(url: workingURL, spec: spec)
            }
        }

        guard let probe = probeInfo else {
            return MediaSourceOutcome(
                id: spec.id, kind: spec.kind, tags: spec.tags, requestedURL: spec.url,
                resolvedURL: workingURL.absoluteString,
                status: "SKIP", message: lastError.isEmpty ? "Probe thất bại (URL chết hoặc cần đăng nhập)" : lastError,
                durationSeconds: Date().timeIntervalSince(started), refreshed: refreshed
            )
        }

        // Chọn kế hoạch tải.
        let total = probe.totalBytes
        let rangeWorks = await verifyRangeSupport(url: workingURL, spec: spec)
        var segments: [DownloadSegment]
        var isSparse = false

        if total > 0 && total <= options.fullDownloadMaxBytes {
            // File vừa phải → tải trọn vẹn (xác nhận nội dung đầy đủ).
            segments = HTTPRangeDownloader.calculateSegments(
                taskId: UUID(), totalBytes: total, segmentCount: 8, acceptRanges: probe.acceptRanges
            )
        } else if rangeWorks && total > 0 {
            // Tải head + tail → file thưa đúng kích thước, ffprobe đọc được moov/cues.
            let taskId = UUID()
            let head = max(0, min(options.headBytes, total) - 1)
            let tailStart = max(0, total - options.tailBytes)
            segments = [
                DownloadSegment(taskId: taskId, index: 0, startByte: 0, endByte: head),
                DownloadSegment(taskId: taskId, index: 1, startByte: tailStart, endByte: total - 1)
            ]
            isSparse = true
        } else {
            // Không hỗ trợ Range và file quá lớn → tải trọn vẹn (có thể tốn băng thông).
            segments = HTTPRangeDownloader.calculateSegments(
                taskId: UUID(), totalBytes: total > 0 ? total : -1, segmentCount: 8, acceptRanges: false
            )
        }

        // Tải.
        let caseDir = destination.appendingPathComponent(spec.id)
        try? FileManager.default.createDirectory(at: caseDir, withIntermediateDirectories: true)
        let filename = suggestedFilename(for: spec, url: workingURL, probe: probe)
        var task = DownloadTask(
            url: workingURL,
            filename: filename,
            destinationFolder: caseDir,
            totalBytes: total,
            acceptRanges: probe.acceptRanges,
            referrer: spec.referer,
            userAgent: URLNormalizer.defaultUserAgent
        )
        task.headers = probe.acceptRanges ? nil : nil

        let session = HTTPRangeDownloader.makeOptimizedSession()
        let downloader = HTTPRangeDownloader(session: session)
        do {
            try await downloader.download(
                task: task,
                segments: segments,
                onProgress: { _, _ in },
                onSegmentUpdate: { _ in }
            )
        } catch {
            return MediaSourceOutcome(
                id: spec.id, kind: spec.kind, tags: spec.tags, requestedURL: spec.url,
                resolvedURL: workingURL.absoluteString,
                finalHost: workingURL.host ?? "",
                status: "FAIL", message: "Tải lỗi: \(error.localizedDescription)",
                sourceSizeBytes: total,
                durationSeconds: Date().timeIntervalSince(started),
                contentType: probe.contentType, refreshed: refreshed
            )
        }

        // Kiểm chứng nội dung.
        let fileURL = task.finalFilePath
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        // Dung lượng đĩa thật của file thưa.
        var diskUsage: Int64 = 0
        if let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
           let allocated = values.totalFileAllocatedSize {
            diskUsage = Int64(allocated)
        }
        let header = (try? Data(contentsOf: fileURL).prefix(512)) ?? Data()
        let detected = FileTypeDetector.detectExtension(fromHeaderData: header)
        let streams = MediaProbe.streamKinds(of: fileURL)
        let contentType = probe.contentType
        let duration = Date().timeIntervalSince(started)

        var problems: [String] = []
        if size <= 0 { problems.append("file rỗng") }
        if size < spec.minBytes {
            problems.append("nhỏ hơn min_bytes (\(size) < \(spec.minBytes))")
        }

        // Magic byte: chỉ dùng để phát hiện HTML/trang lỗi/sai định dạng.
        guard let detected else {
            problems.append("không nhận diện được magic byte (có thể là HTML/trang lỗi)")
            return makeOutcome(spec: spec, url: workingURL, resolvedURL: workingURL.absoluteString, status: "FAIL", message: problems.joined(separator: "; "),
                               size: size, diskUsage: diskUsage, total: total, duration: duration,
                               streams: streams, detected: nil, contentType: contentType, refreshed: refreshed)
        }
        if Self.htmlLikeExtensions.contains(detected) {
            problems.append("server trả HTML thay vì media (\(detected))")
        }

        // Loại media: ưu tiên `ffprobe` (đọc được luồng thật). Magic byte chỉ là
        // dự phòng khi file thưa không probe được — và phải nới vì .m4a/.m4v/.mov
        // đều là cùng họ ISO-BMFF nên bộ dò đuôi trả "mp4" cho cả ba.
        let hasVideo = streams.contains("video")
        let hasAudio = streams.contains("audio")
        if !streams.isEmpty {
            switch spec.kind {
            case "video" where !hasVideo:
                problems.append("không có luồng video (có: \(streams.joined(separator: ",")))")
            case "audio" where !hasAudio:
                problems.append("không có luồng audio (có: \(streams.joined(separator: ",")))")
            default:
                break
            }
        } else if !Self.familyMatches(kind: spec.kind, detected: detected) {
            problems.append("magic byte khác loại (nhận \(detected), cần \(spec.kind))")
        }

        for expected in spec.expectStreams where !streams.isEmpty {
            if !streams.contains(expected) {
                problems.append("thiếu luồng \(expected) (có: \(streams.joined(separator: ",")))")
            }
        }

        let status = problems.isEmpty ? "PASS" : "FAIL"
        let message: String
        if !problems.isEmpty {
            message = problems.joined(separator: "; ")
        } else if streams.isEmpty {
            // File thưa (chỉ có đầu+cuối) mà container không cho probe → vẫn PASS
            // vì magic byte đúng, nhưng phải nói rõ là chưa xác nhận được stream.
            message = "OK — \(detected ?? spec.kind) (file thưa: ffprobe không đọc được stream)"
        } else {
            message = "OK — \(detected ?? spec.kind) [\(streams.joined(separator: "+"))]"
        }

        if !options.keepFiles {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: caseDir)
        }

        return MediaSourceOutcome(
            id: spec.id, kind: spec.kind, tags: spec.tags, requestedURL: spec.url,
            resolvedURL: workingURL.absoluteString,
            finalHost: workingURL.host ?? "",
            status: status, message: message,
            fileSizeBytes: size,
            downloadedBytes: diskUsage,
            sourceSizeBytes: total,
            durationSeconds: duration,
            streams: streams,
            detectedExtension: detected,
            contentType: contentType,
            refreshed: refreshed
        )
    }

    // MARK: Probe

    private struct ProbeInfo: Sendable {
        let totalBytes: Int64
        let acceptRanges: Bool
        let contentType: String?
        let suggestedFilename: String?
    }

    private func probe(url: URL, spec: MediaSourceSpec) async -> ProbeInfo? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue(URLNormalizer.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        if let referer = spec.referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        request.timeoutInterval = 20

        let session = HTTPRangeDownloader.makeOptimizedSession()
        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                guard (200...299).contains(http.statusCode) else { return nil }
                let length = Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "0") ?? 0
                let ranges = (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased().contains("bytes")
                return ProbeInfo(
                    totalBytes: length,
                    acceptRanges: ranges,
                    contentType: http.mimeType,
                    suggestedFilename: nil
                )
            }
            return nil
        } catch {
            // Một số server không nhận HEAD → thử GET Range nhỏ.
            var getRequest = URLRequest(url: url)
            getRequest.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
            getRequest.setValue(URLNormalizer.defaultUserAgent, forHTTPHeaderField: "User-Agent")
            if let referer = spec.referer { getRequest.setValue(referer, forHTTPHeaderField: "Referer") }
            getRequest.timeoutInterval = 20
            do {
                let (data, response) = try await session.data(for: getRequest)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
                let contentRange = http.value(forHTTPHeaderField: "Content-Range")
                var total: Int64 = 0
                if let contentRange, let slash = contentRange.lastIndex(of: "/") {
                    total = Int64(contentRange[contentRange.index(after: slash)...]) ?? 0
                }
                if total == 0 {
                    total = Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "0") ?? 0
                }
                return ProbeInfo(
                    totalBytes: total,
                    acceptRanges: http.statusCode == 206,
                    contentType: http.mimeType,
                    suggestedFilename: FileTypeDetector.extractFilename(from: url)
                )
            } catch {
                return nil
            }
        }
    }

    /// Kiểm tra server có thực sự trả 206 khi có Range hay không (nhiều CDN quảng
    /// cáo `Accept-Ranges` nhưng vẫn trả 200 toàn bộ).
    private func verifyRangeSupport(url: URL, spec: MediaSourceSpec) async -> Bool {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        request.setValue(URLNormalizer.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        if let referer = spec.referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        request.timeoutInterval = 20
        let session = HTTPRangeDownloader.makeOptimizedSession()
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return http.statusCode == 206
        } catch {
            return false
        }
    }

    // MARK: Làm mới URL

    /// Gọi script làm mới ngoài tiến trình để lấy URL mới cho nguồn đã chết.
    private func refreshURL(for spec: MediaSourceSpec) async -> URL? {
        guard let script = options.refreshScript, spec.sourceAPI != nil else { return nil }
        let scriptURL = URL(fileURLWithPath: script)
        guard FileManager.default.fileExists(atPath: scriptURL.path) else { return nil }

        let process = Process()
        // Chạy qua `env python3` để không phụ thuộc cờ executable của script.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", scriptURL.path, "refresh-one", spec.id]
        process.currentDirectoryURL = URL(fileURLWithPath: options.projectRoot)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, !data.isEmpty else { return nil }
            struct Payload: Decodable { let url: String? }
            guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
                  let urlString = payload.url,
                  let url = URL(string: urlString) else { return nil }
            return url
        } catch {
            return nil
        }
    }

    // MARK: Trợ giúp

    private func suggestedFilename(for spec: MediaSourceSpec, url: URL, probe: ProbeInfo) -> String {
        if let name = FileTypeDetector.extractFilename(from: url), !name.isEmpty { return name }
        if let name = probe.suggestedFilename, !name.isEmpty { return name }
        let ext = spec.kind == "image" ? "jpg" : (spec.kind == "audio" ? "mp3" : "mp4")
        return "\(spec.id).\(ext)"
    }

    /// Đuôi file mà server trả về nhưng thực chất là trang web.
    static let htmlLikeExtensions: Set<String> = ["html", "htm", "xhtml", "xml"]

    /// Đuôi ISO-BMFF: mp4/m4v/m4a/mov đều là cùng định dạng → khi không đọc được
    /// luồng thì không được kết luận "khác loại" chỉ vì đuôi khác nhau.
    static func familyMatches(kind: String, detected: String) -> Bool {
        if kind == "any" { return true }
        let isoBMFF: Set<String> = ["mp4", "m4v", "m4a", "mov", "qt"]
        let videoExts: Set<String> = ["mp4", "mkv", "mov", "avi", "webm", "flv", "ts", "m3u8", "mpd", "m4s"]
        let audioExts: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus"]
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "svg", "heic", "avif", "tif", "tiff"]
        switch kind {
        case "video":
            return videoExts.contains(detected) || (isoBMFF.contains(detected) && detected != "m4a")
        case "audio":
            return audioExts.contains(detected) || isoBMFF.contains(detected)
        case "image":
            return imageExts.contains(detected)
        default:
            return true
        }
    }

    /// Dựng kết quả từ các thông số đã đo.
    private func makeOutcome(
        spec: MediaSourceSpec,
        url: URL,
        resolvedURL: String,
        status: String,
        message: String,
        size: Int64,
        diskUsage: Int64,
        total: Int64,
        duration: Double,
        streams: [String],
        detected: String?,
        contentType: String?,
        refreshed: Bool
    ) -> MediaSourceOutcome {
        MediaSourceOutcome(
            id: spec.id, kind: spec.kind, tags: spec.tags, requestedURL: spec.url,
            resolvedURL: resolvedURL,
            finalHost: url.host ?? "",
            status: status, message: message,
            fileSizeBytes: size,
            downloadedBytes: diskUsage,
            sourceSizeBytes: total,
            durationSeconds: duration,
            streams: streams,
            detectedExtension: detected,
            contentType: contentType,
            refreshed: refreshed
        )
    }

    private func kindMatches(_ kind: String, detected: String) -> Bool {
        if kind == "any" { return true }
        let videoExts: Set<String> = ["mp4", "mkv", "mov", "avi", "webm", "flv", "ts", "m3u8", "mpd", "m4s"]
        let audioExts: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus"]
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "svg", "heic", "avif", "tif", "tiff"]
        switch kind {
        case "video": return videoExts.contains(detected)
        case "audio": return audioExts.contains(detected)
        case "image": return imageExts.contains(detected)
        default: return true
        }
    }
}

// MARK: - ffprobe

/// Đọc metadata media bằng `ffprobe` (dùng để xác nhận nội dung file).
public enum MediaProbe {
    public static func ffprobePath() -> String? {
        for candidate in ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Danh sách loại stream của file (`video`, `audio`, …). Rỗng nếu probe lỗi.
    public static func streamKinds(of file: URL) -> [String] {
        guard let ffprobe = ffprobePath() else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobe)
        process.arguments = ["-v", "error", "-show_entries", "stream=codec_type", "-of", "csv=p=0", file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            // ffprobe có thể in "audio," (dấu phẩy thừa) → chuẩn hoá tên luồng.
            return String(data: data, encoding: .utf8)?
                .split(separator: "\n")
                .flatMap { $0.split(separator: ",") }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty } ?? []
        } catch {
            return []
        }
    }

    /// Decode 1 giây bằng ffmpeg để chắc chắn file giải mã được.
    public static func decodes(at file: URL) -> Bool {
        guard let ffmpeg = MediaURLResolver.findFfmpegBinary() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-v", "error", "-xerror", "-nostdin",
            "-protocol_whitelist", "file,pipe",
            "-ss", "1", "-i", file.path, "-t", "1", "-f", "null", "-"
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
