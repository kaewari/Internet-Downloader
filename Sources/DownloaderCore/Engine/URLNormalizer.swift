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
                  encodedURL.host != nil, encodedURL.host?.lowercased() != "web.telegram.org" else {
                return punycodeFallback(str)
            }
            return encodedURL
        }

        return punycodeFallback(str)
    }

    /// Host IDN (Unicode, ví dụ tên miền tiếng Việt) không được percent-encode cả
    /// chuỗi — DNS sẽ từ chối. URLComponents(string:) tự punycode host ( chứng minh:
    /// "phở.vn" → host "xn--ph-rbt.vn") và giữ path/query nguyên dạng Unicode.
    private static func punycodeFallback(_ raw: String) -> URL? {
        guard let comps = URLComponents(string: raw),
              let scheme = comps.scheme?.lowercased(), ["http", "https"].contains(scheme),
              comps.host != nil else { return nil }
        guard let url = comps.url else { return nil }
        guard url.host?.lowercased() != "web.telegram.org" else { return nil }
        return url
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
            "eporner.com", "redtube.com", "youporn.com",
            // Link rút gọn — cần resolve mới biết nền tảng, nhưng vẫn phải được
            // nhận diện là nền tảng để không xử lý như trang chủ.
            "dai.ly", "b23.tv", "t.co"
        ]
        return knownPlatforms.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    public static func isBarePlatformHomeURL(_ url: URL) -> Bool {
        guard isVideoPlatformURL(url) else { return false }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let query = (url.query ?? "").lowercased()
        let barePaths: Set<String> = ["", "home", "feed", "foryou", "explore"]
        if barePaths.contains(path) {
            if !query.contains("v=") && !query.contains("video_id=") && !query.contains("watch") {
                return true
            }
        }
        return false
    }

    /// Hai host có cùng "site" không (eTLD+1 tối thiểu).
    /// Dùng để quyết định có giữ cookie khi URL được resolve sang host khác:
    /// `m.youtube.com` → `youtube.com` vẫn giữ, `youtube.com` → `cdn.vendor.net` thì bỏ.
    ///
    /// A-F16: trước đây chỉ so 2 nhãn cuối nên `evil.co.uk` và `shop.co.uk`
    /// bị coi là cùng site → leak cookie sang domain lạ. Với các public suffix
    /// 2 nhãn (co.uk, com.au, co.jp…) phải so tối thiểu 3 nhãn.
    public static func isSameSiteDomain(_ hostA: String, _ hostB: String) -> Bool {
        let a = hostA.lowercased()
        let b = hostB.lowercased()
        if a == b { return true }
        return registrableDomain(a) == registrableDomain(b)
    }

    /// Suffix công cộng 2 nhãn phổ biến (subset PSL — đủ chặn nhầm lẫn
    /// `*.co.uk`/`*.com.au`/`*.co.jp`… mà không cần bundle toàn bộ PSL).
    private static let twoLabelPublicSuffixes: Set<String> = [
        "co.uk", "org.uk", "me.uk", "net.uk", "ac.uk", "gov.uk", "nhs.uk", "police.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "asn.au", "id.au",
        "co.jp", "ne.jp", "or.jp", "go.jp", "ac.jp", "ed.jp",
        "co.kr", "ne.kr", "or.kr", "go.kr", "ac.kr",
        "com.br", "net.br", "org.br", "gov.br", "edu.br",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
        "com.tw", "net.tw", "org.tw", "gov.tw",
        "co.nz", "net.nz", "org.nz", "govt.nz",
        "co.in", "net.in", "org.in", "gov.in", "ac.in",
        "co.za", "net.za", "org.za", "gov.za", "ac.za",
        "com.sg", "com.hk", "com.mx", "com.ar", "com.tr", "com.vn", "com.ph",
        "co.id", "co.th", "com.my", "com.ng", "co.ke"
    ]

    /// Domain có thể đăng ký (eTLD+1): 2 nhãn, hoặc 3 nhãn khi suffix là
    /// public suffix 2 nhãn (ví dụ `shop.co.uk`, không phải `co.uk`).
    static func registrableDomain(_ host: String) -> String {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return host }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if twoLabelPublicSuffixes.contains(lastTwo), labels.count >= 3 {
            return labels.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }
}
