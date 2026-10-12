import Foundation

public struct URLNormalizer: Sendable {
    public static let defaultUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"

    public static func normalize(_ urlString: String) -> URL? {
        var str = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.isEmpty { return nil }

        // 1. Data URLs
        if str.hasPrefix("data:") {
            return URL(string: str)
        }

        // Blob and authenticated Telegram Web endpoints belong to the browser.
        if str.lowercased().hasPrefix("blob:") { return nil }

        // 3. Missing scheme -> auto-prepend https://
        if !str.contains("://") && !str.hasPrefix("data:") {
            str = "https://" + str
        }

        // 4. Try standard URL parsing
        if let directURL = URL(string: str), ["http", "https"].contains(directURL.scheme?.lowercased() ?? ""),
           directURL.host != nil, directURL.host?.lowercased() != "web.telegram.org" {
            return directURL
        }

        // 5. Percent-encode unescaped unicode characters (Vietnamese, spaces, etc.)
        // Preserve RFC 3986 reserved delimiters (:/?#[]@!$&'()*+,;=)
        var allowed = CharacterSet.urlFragmentAllowed
        allowed.formUnion(CharacterSet.urlQueryAllowed)
        allowed.formUnion(CharacterSet.urlPathAllowed)
        allowed.insert(charactersIn: ":/?#[]@!$&'()*+,;=")

        if let encoded = str.addingPercentEncoding(withAllowedCharacters: allowed),
           let encodedURL = URL(string: encoded) {
            guard ["http", "https"].contains(encodedURL.scheme?.lowercased() ?? ""),
                  encodedURL.host != nil, encodedURL.host?.lowercased() != "web.telegram.org" else { return nil }
            return encodedURL
        }

        return nil
    }

    public static func isVideoPlatformURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let knownPlatforms = [
            "youtube.com", "youtu.be",
            "tiktok.com",
            "facebook.com", "fb.watch", "fb.com",
            "instagram.com", "threads.net",
            "twitter.com", "x.com",
            "vimeo.com",
            "dailymotion.com",
            "bilibili.com",
            "twitch.tv",
            "reddit.com",
            "pinterest.com",
            "pornhub.com",
            "xvideos.com",
            "spankbang.com",
            "hentaivn.tv", "hentaivn.moe", "hentaivn.net", "hentaivn.fun",
            "njav.tv", "njav.org",
            "xnhau.com", "xnhau.net",
            "eporner.com", "redtube.com", "youporn.com"
        ]
        return knownPlatforms.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
