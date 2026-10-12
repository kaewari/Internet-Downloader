import Foundation

public struct ResolvedMedia: Sendable {
    public let directURL: URL
    public let title: String?
    public let suggestedFilename: String?
    public let isHLS: Bool
    public let headers: [String: String]
    public let extractor: String

    public init(
        directURL: URL,
        title: String? = nil,
        suggestedFilename: String? = nil,
        isHLS: Bool = false,
        headers: [String: String] = [:],
        extractor: String = "direct"
    ) {
        self.directURL = directURL
        self.title = title
        self.suggestedFilename = suggestedFilename
        self.isHLS = isHLS
        self.headers = headers
        self.extractor = extractor
    }
}

public struct MediaURLResolver: Sendable {
    public static func findYtDlpBinary() -> String? {
        let candidates = [
            "/Library/Frameworks/Python.framework/Versions/3.14/bin/yt-dlp",
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/usr/bin/yt-dlp"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Try `which yt-dlp`
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["yt-dlp"]
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !str.isEmpty && FileManager.default.isExecutableFile(atPath: str) {
                    return str
                }
            }
        } catch {}

        return nil
    }

    public static func findFfmpegBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
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
            "jpg", "jpeg", "png", "gif", "webp", "svg", "bmp", "pdf"
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
        if URLNormalizer.isVideoPlatformURL(url) || (!isDirectMediaURL(url) && findYtDlpBinary() != nil) {
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
                if !URLNormalizer.isVideoPlatformURL(url), let ck = cookies, !ck.isEmpty {
                    args.append(contentsOf: ["--add-header", "Cookie: \(ck)"])
                }
                args.append(url.absoluteString)
                proc.arguments = args

                let outPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = Pipe()

                do {
                    try proc.run()
                    proc.waitUntilExit()

                    if proc.terminationStatus == 0 {
                        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                        if let outputStr = String(data: data, encoding: .utf8) {
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
                    }
                } catch {}

                continuation.resume(returning: nil)
            }
        }
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
                var args = [
                    "--print", "%(title)s",
                    "--print", "%(ext)s",
                    "-g",
                    "--no-playlist",
                    "--no-warnings"
                ]
                if let ua = userAgent, !ua.isEmpty {
                    args.append(contentsOf: ["--user-agent", ua])
                }
                if !URLNormalizer.isVideoPlatformURL(url), let ck = cookies, !ck.isEmpty {
                    args.append(contentsOf: ["--add-header", "Cookie: \(ck)"])
                }
                args.append(url.absoluteString)

                proc.arguments = args
                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe

                do {
                    try proc.run()
                    proc.waitUntilExit()

                    if proc.terminationStatus == 0 {
                        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                        if let outputStr = String(data: data, encoding: .utf8) {
                            let lines = outputStr.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                            var title = "video"
                            var ext = "mp4"
                            var directURLStr: String?

                            for line in lines {
                                if line.hasPrefix("http://") || line.hasPrefix("https://") {
                                    if directURLStr == nil {
                                        directURLStr = line
                                    }
                                } else if title == "video" {
                                    title = line.replacingOccurrences(of: "/", with: "-")
                                } else if ext == "mp4" && !line.contains(" ") && line.count < 10 {
                                    ext = line
                                }
                            }

                            if let directStr = directURLStr, let directURL = URL(string: directStr) {
                                let filename = "\(title).\(ext)"
                                let isHLS = directStr.contains(".m3u8")
                                continuation.resume(returning: ResolvedMedia(
                                    directURL: directURL,
                                    title: title,
                                    suggestedFilename: filename,
                                    isHLS: isHLS,
                                    headers: ["Referer": url.absoluteString],
                                    extractor: "yt-dlp"
                                ))
                                return
                            }
                        }
                    }
                } catch {}

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
        if let headers = customHeaders {
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        }

        guard let (data, response) = try? await HTTPRangeDownloader.makeOptimizedSession().data(for: req),
              let httpResp = response as? HTTPURLResponse,
              httpResp.statusCode == 200,
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
