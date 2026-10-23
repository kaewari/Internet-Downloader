import Foundation
import Darwin

/// Vai trò của một stream media sau khi tách từ metadata của yt-dlp.
public enum MediaStreamRole: String, Sendable {
    case video
    case audio
}

/// Một stream media đã resolve được URL tải trực tiếp.
public struct ResolvedStream: Sendable {
    public let url: URL
    public let role: MediaStreamRole
    /// true khi stream video này đã chứa sẵn phần âm thanh (format hợp nhất).
    public let includesAudio: Bool
    public let ext: String?
    public let formatID: String?

    public init(
        url: URL,
        role: MediaStreamRole,
        includesAudio: Bool = false,
        ext: String? = nil,
        formatID: String? = nil
    ) {
        self.url = url
        self.role = role
        self.includesAudio = includesAudio
        self.ext = ext
        self.formatID = formatID
    }
}

/// Một format media lấy từ JSON của `yt-dlp -J`.
public struct YtDlpStreamCandidate: Sendable {
    public let url: URL
    public let role: MediaStreamRole
    public let includesAudio: Bool
    public let ext: String?
    public let formatID: String?
    public let height: Int
    public let tbr: Double
    public let abr: Double

    public init(
        url: URL,
        role: MediaStreamRole,
        includesAudio: Bool,
        ext: String? = nil,
        formatID: String? = nil,
        height: Int = 0,
        tbr: Double = 0,
        abr: Double = 0
    ) {
        self.url = url
        self.role = role
        self.includesAudio = includesAudio
        self.ext = ext
        self.formatID = formatID
        self.height = height
        self.tbr = tbr
        self.abr = abr
    }
}

/// Kết quả chọn stream từ metadata của yt-dlp.
public struct YtDlpSelection: Sendable {
    public let title: String?
    public let ext: String?
    public let streams: [YtDlpStreamCandidate]

    public init(title: String?, ext: String?, streams: [YtDlpStreamCandidate]) {
        self.title = title
        self.ext = ext
        self.streams = streams
    }

    /// true khi phải ghép video + audio bằng ffmpeg (nguồn không có format hợp nhất).
    public var requiresMux: Bool {
        let hasVideoOnly = streams.contains { $0.role == .video && !$0.includesAudio }
        let hasAudio = streams.contains { $0.role == .audio }
        return hasVideoOnly && hasAudio
    }
}

public struct ResolvedMedia: Sendable {
    public let directURL: URL
    public let title: String?
    public let suggestedFilename: String?
    public let isHLS: Bool
    public let headers: [String: String]
    public let extractor: String
    /// Các stream riêng biệt (video-only + audio-only) khi nguồn dùng DASH.
    public let mediaStreams: [ResolvedStream]

    public init(
        directURL: URL,
        title: String? = nil,
        suggestedFilename: String? = nil,
        isHLS: Bool = false,
        headers: [String: String] = [:],
        extractor: String = "direct",
        mediaStreams: [ResolvedStream] = []
    ) {
        self.directURL = directURL
        self.title = title
        self.suggestedFilename = suggestedFilename
        self.isHLS = isHLS
        self.headers = headers
        self.extractor = extractor
        self.mediaStreams = mediaStreams
    }

    /// true khi video và âm thanh nằm ở hai file khác nhau → cần ghép bằng ffmpeg.
    /// Nếu false mà `mediaStreams` rỗng thì nguồn chỉ có một file (đã hợp nhất).
    public var requiresMux: Bool {
        let hasVideoOnly = mediaStreams.contains { $0.role == .video && !$0.includesAudio }
        let hasAudio = mediaStreams.contains { $0.role == .audio }
        return hasVideoOnly && hasAudio
    }

    public var videoStream: ResolvedStream? {
        mediaStreams.first { $0.role == .video }
    }

    public var audioStream: ResolvedStream? {
        mediaStreams.first { $0.role == .audio }
    }

    /// Nguồn có âm thanh hay không, theo metadata của resolver:
    /// `nil` = không đủ thông tin (ví dụ link file trực tiếp).
    public var declaredAudio: Bool? {
        if mediaStreams.isEmpty { return nil }
        if requiresMux { return true }
        if let video = mediaStreams.first(where: { $0.role == .video }) {
            return video.includesAudio
        }
        return mediaStreams.contains { $0.role == .audio }
    }
}

public struct MediaURLResolver: Sendable {
    public static func findYtDlpBinary() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["IDM_YTDLP_PATH"],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        var candidates = [
            "/Library/Frameworks/Python.framework/Versions/3.14/bin/yt-dlp",
            "/opt/homebrew/bin/yt-dlp",
            "/opt/local/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/usr/bin/yt-dlp",
            (environment["HOME"] ?? NSHomeDirectory()) + "/.local/bin/yt-dlp",
            (environment["HOME"] ?? NSHomeDirectory()) + "/.pyenv/shims/yt-dlp"
        ]
        // pipx / pip --user trên macOS hay đặt binary trong ~/Library/Python/*/bin.
        let pythonBins = (environment["HOME"] ?? NSHomeDirectory()) + "/Library/Python"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: pythonBins) {
            for version in versions.sorted(by: >) {
                candidates.append("\(pythonBins)/\(version)/bin/yt-dlp")
            }
        }
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return MediaIntegrity.whichBinary("yt-dlp", environment: environment)
    }

    /// Chờ process kết thúc với timeout; quá hạn thì terminate rồi SIGKILL.
    /// Mọi lần chờ đều có giới hạn → không bao giờ treo vô hạn.
    /// Trả về true nếu process đã tự kết thúc trong hạn.
    static func runProcessWithTimeout(_ proc: Process, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while proc.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if !proc.isRunning { return true }

        proc.terminate()
        let killDeadline = Date().addingTimeInterval(3)
        while proc.isRunning && Date() < killDeadline {
            usleep(50_000)
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
            let reapDeadline = Date().addingTimeInterval(1)
            while proc.isRunning && Date() < reapDeadline {
                usleep(50_000)
            }
        }
        return false
    }

    /// Bộ đệm dữ liệu an toàn khi đọc song song từ nhiều thread.
    final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock(); storage.append(chunk); lock.unlock()
        }

        var value: Data {
            lock.lock(); defer { lock.unlock() }; return storage
        }
    }

    /// Chạy process và thu stdout/stderr mà không sợ kẹt pipe.
    /// - (finished, stdout, stderr); `finished == false` nghĩa là đã bị timeout/kill.
    static func runProcessCapturingOutput(
        _ proc: Process,
        seconds: TimeInterval
    ) -> (finished: Bool, stdout: Data, stderr: Data) {
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outBox.append(outPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.append(errPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        do {
            try proc.run()
        } catch {
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
            return (false, Data(), Data())
        }

        let finished = runProcessWithTimeout(proc, seconds: seconds)
        if !finished {
            // Đóng handle để các thread đọc thoát ra khỏi readDataToEndOfFile.
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
        }
        _ = group.wait(timeout: .now() + 2.0)
        return (finished, outBox.value, errBox.value)
    }

    public static func findFfmpegBinary() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["IDM_FFMPEG_PATH"],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/opt/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
            (environment["HOME"] ?? NSHomeDirectory()) + "/.local/bin/ffmpeg"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Máy cài bằng MacPorts/pipx/venv: dò PATH (có timeout, không treo worker).
        return MediaIntegrity.whichBinary("ffmpeg", environment: environment)
    }

    /// URL có phải một **trang HTML** (không phải file media) hay không.
    ///
    /// Dùng để quyết định có thể "cứu" audio bằng cách resolve lại trang gốc
    /// hay không: referrer là trang xem video mới đáng thử, referrer là CDN media
    /// thì không.
    public static func isHTMLPageURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else {
            return false
        }
        if URLNormalizer.isVideoPlatformURL(url) { return true }
        if isDirectMediaURL(url) { return false }
        let ext = url.pathExtension.lowercased()
        let pageExtensions: Set<String> = ["", "html", "htm", "php", "asp", "aspx", "jsp", "cgi", "shtml", "do", "action"]
        return pageExtensions.contains(ext)
    }

    /// URL có khả năng là media thật hay không (dùng khi quét thẻ meta).
    ///
    /// Bỏ qua các trang nhúng/điều hướng không phải media: `/embed/…`, `/watch…`,
    /// `/reel/…`, `/status/…`… Nếu không, `og:video` của YouTube (trỏ tới
    /// `youtube.com/embed/<id>`) sẽ bị coi là media và tải về một trang HTML.
    public static func isPlausibleMediaURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        let path = url.path.lowercased()
        let nonMediaPaths = ["/embed", "/watch", "/reel", "/reels", "/status", "/shorts", "/video", "/posts", "/p/", "/live", "/tv/"]
        for marker in nonMediaPaths {
            if path == marker || path.hasPrefix(marker + "/") {
                return false
            }
        }
        // URL không có đuôi file vẫn có thể là media (CDN dùng đường dẫn opaque),
        // nhưng phải có dấu hiệu media trong query hoặc đuôi file.
        let ext = url.pathExtension.lowercased()
        let mediaExts: Set<String> = [
            "mp4", "webm", "mkv", "mov", "avi", "flv", "ts", "m3u8", "mpd",
            "mp3", "m4a", "aac", "flac", "wav", "ogg", "m4s", "m4f", "jpg", "jpeg", "png", "gif", "webp"
        ]
        if mediaExts.contains(ext) { return true }
        let lowerQuery = (url.query ?? "").lowercased()
        if lowerQuery.contains(".m3u8") || lowerQuery.contains(".mpd") || lowerQuery.contains("format=mp4") {
            return true
        }
        // Đường dẫn có dấu hiệu media (ví dụ /video/, /stream/, /hls/)
        let pathLower = path
        if pathLower.contains("/video") || pathLower.contains("/stream") || pathLower.contains("/hls") || pathLower.contains("/media") {
            return true
        }
        return false
    }

    public static func isDirectMediaURL(_ url: URL) -> Bool {
        // Known media sharing platforms need resolution even if path looks simple
        if URLNormalizer.isVideoPlatformURL(url) {
            return false
        }
        // Known embed or probe endpoints that need resolution even if ending in .m3u8
        if url.host?.contains("recordplay.biz") == true {
            return false
        }

        let ext = url.pathExtension.lowercased()
        let directExts = [
            "mp4", "mkv", "avi", "mov", "webm", "flv", "ts", "m3u8",
            "mp3", "wav", "flac", "aac", "m4a", "ogg",
            "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "iso", "dmg", "pkg",
            "jpg", "jpeg", "png", "gif", "webp", "svg", "bmp", "pdf",
            "docx", "xlsx", "pptx", "doc", "xls", "ppt", "txt", "epub", "csv",
            "apk", "exe", "msi", "ipa", "json", "xml"
        ]
        return directExts.contains(ext)
    }

    public static func resolve(
        url: URL,
        customHeaders: [String: String]? = nil,
        userAgent: String? = nil,
        cookies: String? = nil
    ) async -> ResolvedMedia {
        // Embed pages or probe endpoints (recordplay.biz)
        if url.host?.contains("recordplay.biz") == true {
            var embedURL = url
            if url.path.contains("/stream/"), let refStr = customHeaders?["Referer"], let refURL = URL(string: refStr), refURL.path.contains("/e/") {
                embedURL = refURL
            }
            if let resolved = await resolveEmbedStream(embedURL: embedURL, userAgent: userAgent) {
                return resolved
            }
        }

        if URLNormalizer.isBarePlatformHomeURL(url) {
            return ResolvedMedia(
                directURL: url,
                title: "Trang chủ",
                suggestedFilename: "unsupported.mp4",
                isHLS: false,
                headers: customHeaders ?? [:],
                extractor: "unsupported_bare_home"
            )
        }

        // 1. If it's already a direct file, return directly
        if isDirectMediaURL(url) {
            let isHLS = url.pathExtension.lowercased() == "m3u8"
            return ResolvedMedia(
                directURL: url,
                title: url.deletingPathExtension().lastPathComponent,
                suggestedFilename: url.lastPathComponent,
                isHLS: isHLS,
                headers: customHeaders ?? [:],
                extractor: "direct"
            )
        }

        // 2. Try yt-dlp if available
        if let ytdlp = findYtDlpBinary() {
            if let resolved = await resolveWithYtDlp(binaryPath: ytdlp, url: url, userAgent: userAgent, cookies: cookies) {
                return resolved
            }
        }

        // 3. Fallback: Native HTTP HTML scraping (OpenGraph, Twitter cards, HTML5 video/image)
        if let fallback = await resolveWithHTMLFallback(url: url, customHeaders: customHeaders, userAgent: userAgent) {
            return fallback
        }

        // 4. Default: Return original URL as-is
        let isHLS = url.pathExtension.lowercased() == "m3u8" || url.absoluteString.contains(".m3u8")
        let fallbackName = url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent
        return ResolvedMedia(
            directURL: url,
            title: fallbackName,
            suggestedFilename: fallbackName,
            isHLS: isHLS,
            headers: customHeaders ?? [:],
            extractor: "fallback_raw"
        )
    }

    public static func probeMediaSizeAndTitle(
        url: URL,
        userAgent: String? = nil,
        cookies: String? = nil
    ) async -> (size: Int64, title: String?) {
        // 1. Nếu là video platform URL hoặc yt-dlp có thể trích xuất
        if (URLNormalizer.isVideoPlatformURL(url) && !URLNormalizer.isBarePlatformHomeURL(url)) || (!isDirectMediaURL(url) && findYtDlpBinary() != nil && !URLNormalizer.isBarePlatformHomeURL(url)) {
            if let ytdlp = findYtDlpBinary() {
                if let result = await probeWithYtDlp(binaryPath: ytdlp, url: url, userAgent: userAgent, cookies: cookies) {
                    return result
                }
            }
        }

        // 2. Nếu là URL trực tiếp, thử gửi HTTP HEAD request để lấy Content-Length
        if url.scheme == "http" || url.scheme == "https" {
            var req = URLRequest(url: url)
            req.httpMethod = "HEAD"
            req.setValue(userAgent ?? URLNormalizer.defaultUserAgent, forHTTPHeaderField: "User-Agent")
            if let cookies = cookies, !cookies.isEmpty {
                req.setValue(cookies, forHTTPHeaderField: "Cookie")
            }
            if let (_, resp) = try? await HTTPRangeDownloader.makeOptimizedSession().data(for: req),
               let httpResp = resp as? HTTPURLResponse,
               (200...299).contains(httpResp.statusCode) {
                if let clStr = httpResp.value(forHTTPHeaderField: "Content-Length"), let cl = Int64(clStr), cl > 0 {
                    let title = url.deletingPathExtension().lastPathComponent
                    return (size: cl, title: title.isEmpty ? nil : title)
                }
            }
        }

        return (size: -1, title: nil)
    }

    private static func probeWithYtDlp(
        binaryPath: String,
        url: URL,
        userAgent: String?,
        cookies: String?
    ) async -> (size: Int64, title: String?)? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: binaryPath)
                var args = [
                    "--print", "%(title)s",
                    "--print", "%(filesize_approx,filesize)s",
                    "--no-playlist",
                    "--no-warnings"
                ]
                if let ua = userAgent, !ua.isEmpty {
                    args.append(contentsOf: ["--user-agent", ua])
                }
                if let ck = cookies, !ck.isEmpty {
                    args.append(contentsOf: ["--add-header", "Cookie: \(ck)"])
                }
                args.append(url.absoluteString)
                proc.arguments = args

                // Timeout 15s: yt-dlp generic extractor treo vĩnh viễn trên
                // link khó — terminate để giải phóng slot.
                let result = runProcessCapturingOutput(proc, seconds: 15)
                if result.finished, proc.terminationStatus == 0,
                   let outputStr = String(data: result.stdout, encoding: .utf8) {
                    let lines = outputStr.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    var title: String?
                    var size: Int64 = -1

                    if lines.count >= 1 {
                        title = lines[0].replacingOccurrences(of: "/", with: "-")
                    }
                    if lines.count >= 2, let parsedSize = Int64(lines[1]), parsedSize > 0 {
                        size = parsedSize
                    }
                    continuation.resume(returning: (size: size, title: title))
                    return
                }

                continuation.resume(returning: nil)
            }
        }
    }

    /// Chọn các stream tải được từ JSON của `yt-dlp -J`.
    ///
    /// yt-dlp mặc định chọn `bv*+ba/b`: với nguồn DASH (YouTube, Bilibili, …) đó là
    /// **hai** file riêng — video-only và audio-only. Nếu chỉ giữ URL đầu tiên thì
    /// file tải về **mất tiếng**. Hàm này ưu tiên format hợp nhất (video+audio),
    /// nếu không có thì trả về cả hai stream để ghép bằng ffmpeg.
    public static func selectStreams(fromYtDlpJSON data: Data) -> YtDlpSelection? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dict = object as? [String: Any]
        else { return nil }

        let title = dict["title"] as? String
        let topExt = dict["ext"] as? String

        var candidates: [YtDlpStreamCandidate] = []
        let allFormats = dict["formats"] as? [[String: Any]] ?? []
        var rawFormats: [[String: Any]] = []
        if let requested = dict["requested_formats"] as? [[String: Any]], !requested.isEmpty {
            rawFormats = requested
        } else {
            rawFormats = allFormats
        }
        candidates = parseCandidates(rawFormats)

        // Nguồn chỉ trả video (không kèm audio) → tìm thêm audio-only trong
        // `formats[]` để ghép, nếu có.
        if !candidates.contains(where: { $0.role == .audio }) {
            let extraAudio = parseCandidates(allFormats).filter { $0.role == .audio }
            candidates.append(contentsOf: extraAudio)
        }

        guard !candidates.isEmpty else { return nil }

        // 1) Ưu tiên format hợp nhất (video + audio trong cùng một file).
        let combinedCandidates = candidates.filter { $0.role == .video && $0.includesAudio }
        let combined = combinedCandidates.sorted { isBetterVideo($0, $1) }.first
        if let best = combined {
            return YtDlpSelection(title: title, ext: best.ext ?? topExt, streams: [best])
        }

        // 2) Không có format hợp nhất → lấy video-only + audio-only để ghép.
        var streams: [YtDlpStreamCandidate] = []
        let videoOnlyCandidates = candidates.filter { $0.role == .video && !$0.includesAudio }
        if let video = videoOnlyCandidates.sorted(by: { isBetterVideo($0, $1) }).first {
            streams.append(video)
        }
        let audioCandidates = candidates.filter { $0.role == .audio }
        if let audio = audioCandidates.sorted(by: { isBetterAudio($0, $1) }).first {
            streams.append(audio)
        }

        guard !streams.isEmpty else { return nil }
        return YtDlpSelection(title: title, ext: streams.first?.ext ?? topExt, streams: streams)
    }

    /// Chuyển danh sách format của yt-dlp thành candidate đã phân loại.
    private static func parseCandidates(_ formats: [[String: Any]]) -> [YtDlpStreamCandidate] {
        var candidates: [YtDlpStreamCandidate] = []
        for format in formats {
            guard let urlString = format["url"] as? String,
                  let mediaURL = URL(string: urlString) else { continue }
            let protocolName = ((format["protocol"] as? String) ?? "https").lowercased()
            guard ["http", "https", "m3u8", "m3u8_native", "http_dash_segments"].contains(protocolName) else { continue }

            // yt-dlp dùng "none" để nói "không có" và null/missing để "không rõ".
            let vcodec = (format["vcodec"] as? String)?.lowercased()
            let acodec = (format["acodec"] as? String)?.lowercased()
            let videoKnown = !(vcodec?.isEmpty ?? true) && vcodec != "none"
            let audioKnown = !(acodec?.isEmpty ?? true) && acodec != "none"

            let formatID = (format["format_id"] as? String) ?? ""
            let formatNote = (format["format_note"] as? String) ?? ""
            let mimeType = ((format["mime_type"] as? String) ?? "").lowercased()
            let hint = "\(formatID) \(formatNote) \(urlString)".lowercased()
            let isPlaylistURL = urlString.lowercased().contains(".m3u8")
            // yt-dlp không phải lúc nào cũng ghi vcodec/acodec cho playlist HLS.
            // Dùng thêm mime + tên format để nhận ra nhánh audio-only, tránh
            // tải mỗi playlist video → file không có tiếng.
            let audioHint = hint.contains("audio") || mimeType.hasPrefix("audio/")
            let videoHint = mimeType.hasPrefix("video/")

            let role: MediaStreamRole
            let includesAudio: Bool
            if videoKnown && audioKnown {
                role = .video
                includesAudio = true
            } else if videoKnown {
                role = .video
                includesAudio = false
            } else if audioKnown {
                role = .audio
                includesAudio = false
            } else if audioHint && !videoHint {
                // Không có thông tin codec nhưng tên format/mime nói rõ đây là nhánh audio.
                role = .audio
                includesAudio = false
            } else if isPlaylistURL {
                // Playlist HLS không ghi codec → coi là nhánh video (audio nằm ở
                // playlist riêng, ví dụ Vimeo's `st=audio` / `st=video`).
                role = .video
                includesAudio = false
            } else {
                // File progressive không ghi codec → coi là file đã hợp nhất
                // (video + audio trong một tệp), ví dụ Vimeo's `http-360p`.
                role = .video
                includesAudio = true
            }

            candidates.append(YtDlpStreamCandidate(
                url: mediaURL,
                role: role,
                includesAudio: includesAudio,
                ext: format["ext"] as? String,
                formatID: format["format_id"] as? String,
                height: (format["height"] as? NSNumber)?.intValue ?? parseHeight(from: hint),
                tbr: (format["tbr"] as? NSNumber)?.doubleValue ?? 0,
                abr: (format["abr"] as? NSNumber)?.doubleValue ?? 0
            ))
        }
        return candidates
    }

    /// Lấy chiều cao từ tên format (ví dụ "http-360p", "hls-...-720").
    private static func parseHeight(from hint: String) -> Int {
        let pattern = #"(?i)(?:^|[^0-9])(\d{3,4})p(?:[^0-9]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let ns = hint as NSString
        guard let match = regex.firstMatch(in: hint, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return 0 }
        return Int(ns.substring(with: match.range(at: 1))) ?? 0
    }

    private static func isBetterVideo(_ a: YtDlpStreamCandidate, _ b: YtDlpStreamCandidate) -> Bool {
        if a.height != b.height { return a.height > b.height }
        return a.tbr > b.tbr
    }

    private static func isBetterAudio(_ a: YtDlpStreamCandidate, _ b: YtDlpStreamCandidate) -> Bool {
        if a.abr != b.abr { return a.abr > b.abr }
        return a.tbr > b.tbr
    }

    private static func resolveWithYtDlp(
        binaryPath: String,
        url: URL,
        userAgent: String?,
        cookies: String?
    ) async -> ResolvedMedia? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: binaryPath)
                // -J trả về JSON đầy đủ: có `requested_formats` nên biết chính xác
                // format nào video-only / audio-only (thay vì đoán qua `-g`).
                var args = ["-J", "--no-playlist", "--no-warnings"]
                if let ua = userAgent, !ua.isEmpty {
                    args.append(contentsOf: ["--user-agent", ua])
                }
                // Cookie phải được truyền cho MỌI host (kể cả nền tảng) để tải được
                // nội dung yêu cầu đăng nhập.
                if let ck = cookies, !ck.isEmpty {
                    args.append(contentsOf: ["--add-header", "Cookie: \(ck)"])
                }
                args.append(url.absoluteString)
                proc.arguments = args

                // Timeout 30s: yt-dlp generic extractor có thể treo vĩnh viễn.
                let result = runProcessCapturingOutput(proc, seconds: 30)

                if result.finished, proc.terminationStatus == 0,
                   let selection = selectStreams(fromYtDlpJSON: result.stdout),
                   let primary = selection.streams.first {
                    let title = selection.title ?? "video"
                    let ext = primary.ext ?? selection.ext ?? "mp4"
                    let filename = "\(title).\(ext)"
                    let isHLS = selection.streams.contains { $0.url.absoluteString.contains(".m3u8") }
                    let resolvedStreams = selection.streams.map {
                        ResolvedStream(
                            url: $0.url,
                            role: $0.role,
                            includesAudio: $0.includesAudio,
                            ext: $0.ext,
                            formatID: $0.formatID
                        )
                    }
                    continuation.resume(returning: ResolvedMedia(
                        directURL: primary.url,
                        title: title,
                        suggestedFilename: filename,
                        isHLS: isHLS,
                        headers: ["Referer": url.absoluteString],
                        extractor: "yt-dlp",
                        mediaStreams: resolvedStreams
                    ))
                    return
                }

                continuation.resume(returning: nil)
            }
        }
    }

    public static func resolveWithHTMLFallback(
        url: URL,
        customHeaders: [String: String]?,
        userAgent: String?
    ) async -> ResolvedMedia? {
        var req = URLRequest(url: url)
        req.setValue(userAgent ?? URLNormalizer.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(url.absoluteString, forHTTPHeaderField: "Referer")
        // Chỉ lấy phần đầu trang: trang phát video có thể rất nặng (vài MB) và
        // thẻ meta thường nằm ở đầu tài liệu.
        req.setValue("bytes=0-524287", forHTTPHeaderField: "Range")
        if let headers = customHeaders {
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        }

        guard let (data, response) = try? await HTTPRangeDownloader.makeOptimizedSession().data(for: req),
              let httpResp = response as? HTTPURLResponse,
              (200...299).contains(httpResp.statusCode),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            return nil
        }

        // Check OpenGraph video: og:video or og:video:url or og:video:secure_url
        let ogPatterns = [
            #"(?i)<meta\s+property=["']og:video(:secure_url|:url)?["']\s+content=["']([^"']+)["']"#,
            #"(?i)<meta\s+content=["']([^"']+)["']\s+property=["']og:video(:secure_url|:url)?["']"#,
            #"(?i)<meta\s+name=["']twitter:player:stream["']\s+content=["']([^"']+)["']"#,
            #"(?i)<video[^>]+src=["']([^"']+)["']"#,
            #"(?i)<source[^>]+src=["']([^"']+)["']"#
        ]

        for pattern in ogPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let nsString = html as NSString
                let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsString.length))
                for match in matches {
                    let groupCount = match.numberOfRanges
                    let targetIndex = groupCount >= 3 ? (match.range(at: 2).location != NSNotFound ? 2 : 1) : 1
                    let matchedRange = match.range(at: targetIndex)
                    if matchedRange.location != NSNotFound {
                        let matchedURLStr = nsString.substring(with: matchedRange)
                        if let resolvedURL = URL(string: matchedURLStr, relativeTo: url)?.absoluteURL {
                            // Ứng dụng web hay dùng og:video trỏ tới TRANG NHÚNG (ví dụ
                            // YouTube → /embed/<id>). Trang đó không phải media: nếu đưa
                            // vào engine tải sẽ nhận HTML và báo "Nguồn trả HTML thay vì file".
                            guard isPlausibleMediaURL(resolvedURL) else { continue }
                            let ext = resolvedURL.pathExtension.lowercased()
                            let isHLS = ext == "m3u8" || matchedURLStr.contains(".m3u8")
                            let filename = resolvedURL.lastPathComponent.isEmpty ? "media_\(UUID().uuidString.prefix(6)).\(ext.isEmpty ? "mp4" : ext)" : resolvedURL.lastPathComponent
                            return ResolvedMedia(
                                directURL: resolvedURL,
                                title: filename,
                                suggestedFilename: filename,
                                isHLS: isHLS,
                                headers: ["Referer": url.absoluteString],
                                extractor: "html_og_parser"
                            )
                        }
                    }
                }
            }
        }

        // Check Dean Edwards packed JavaScript (recordplay.biz, dood, mixdrop, etc.)
        if html.contains("eval(function(p,a,c,k,e,d)") {
            if let unpacked = unpackDeanEdwards(script: html) {
                let m3u8Pattern = #"(?i)https?://[^\s"'<>]+\.(m3u8|txt)[^\s"'<>]*"#
                if let regex = try? NSRegularExpression(pattern: m3u8Pattern, options: []) {
                    let nsUnpacked = unpacked as NSString
                    let matches = regex.matches(in: unpacked, options: [], range: NSRange(location: 0, length: nsUnpacked.length))
                    var candidateURLs: [URL] = []
                    for match in matches {
                        let matchedStr = nsUnpacked.substring(with: match.range)
                        if let resolvedURL = URL(string: matchedStr) {
                            candidateURLs.append(resolvedURL)
                        }
                    }
                    let workingURLs = candidateURLs.filter { !$0.absoluteString.contains("/stream/") }
                    let chosenURL = workingURLs.first(where: { $0.absoluteString.contains(".m3u8") && $0.absoluteString.contains("master") })
                        ?? workingURLs.first(where: { $0.absoluteString.contains(".m3u8") })
                        ?? workingURLs.first(where: { $0.absoluteString.contains("master") })
                        ?? workingURLs.first
                        ?? candidateURLs.first
                    if let directURL = chosenURL {
                        var pageTitle: String?
                        let titlePattern = #"(?i)<title>([^<]+)</title>"#
                        if let tRegex = try? NSRegularExpression(pattern: titlePattern, options: []),
                           let tMatch = tRegex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: (html as NSString).length)),
                           tMatch.numberOfRanges >= 2 {
                            pageTitle = (html as NSString).substring(with: tMatch.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        let filename = (pageTitle ?? url.deletingPathExtension().lastPathComponent).replacingOccurrences(of: "/", with: "-")
                        return ResolvedMedia(
                            directURL: directURL,
                            title: filename,
                            suggestedFilename: filename.hasSuffix(".mp4") ? filename : "\(filename).mp4",
                            isHLS: true,
                            headers: ["Referer": url.absoluteString],
                            extractor: "packed_stream_scraper"
                        )
                    }
                }
            }
        }

        return nil
    }

    public static func resolveEmbedStream(
        embedURL: URL,
        userAgent: String? = nil
    ) async -> ResolvedMedia? {
        return await resolveWithHTMLFallback(url: embedURL, customHeaders: [:], userAgent: userAgent)
    }

    public static func unpackDeanEdwards(script: String) -> String? {
        let pattern = #"eval\(function\(p,a,c,k,e,d\)[^\{]*\{.*?\}\('(.*?)',\s*(\d+)\s*,\s*(\d+)\s*,\s*'(.*?)'\.split\('\|'\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let nsString = script as NSString
        guard let match = regex.firstMatch(in: script, options: [], range: NSRange(location: 0, length: nsString.length)),
              match.numberOfRanges >= 5 else {
            return nil
        }

        let payload = nsString.substring(with: match.range(at: 1))
        guard let radix = Int(nsString.substring(with: match.range(at: 2))),
              let keywordsStr = Optional(nsString.substring(with: match.range(at: 4))) else {
            return nil
        }
        let keywords = keywordsStr.components(separatedBy: "|")

        guard let wordRegex = try? NSRegularExpression(pattern: #"\b[0-9a-zA-Z]+\b"#, options: []) else { return nil }

        let nsPayload = payload as NSString
        var result = ""
        var lastLocation = 0

        let wordMatches = wordRegex.matches(in: payload, options: [], range: NSRange(location: 0, length: nsPayload.length))
        for wMatch in wordMatches {
            let range = wMatch.range
            if range.location > lastLocation {
                result += nsPayload.substring(with: NSRange(location: lastLocation, length: range.location - lastLocation))
            }
            let word = nsPayload.substring(with: range)
            if let index = decodeBaseN(word: word, radix: radix), index < keywords.count, !keywords[index].isEmpty {
                result += keywords[index]
            } else {
                result += word
            }
            lastLocation = range.location + range.length
        }
        if lastLocation < nsPayload.length {
            result += nsPayload.substring(from: lastLocation)
        }
        return result
    }

    private static func decodeBaseN(word: String, radix: Int) -> Int? {
        let digits = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        var val = 0
        for ch in word {
            guard let idx = digits.firstIndex(of: ch) else { return nil }
            let d = digits.distance(from: digits.startIndex, to: idx)
            if d >= radix { return nil }
            val = val * radix + d
        }
        return val
    }
}
