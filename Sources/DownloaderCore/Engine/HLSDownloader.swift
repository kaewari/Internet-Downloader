import Foundation
import CommonCrypto
import os

private let log = Logger(subsystem: "com.internet-downloader", category: "hls-downloader")

public struct HLSByteRange: Sendable, Equatable {
    public let length: Int64
    public let offset: Int64

    public init(length: Int64, offset: Int64) {
        self.length = length
        self.offset = offset
    }
}

public struct HLSKeyInfo: Sendable, Equatable {
    public let method: String
    public let uri: URL
    public let iv: Data?
    public let keyFormat: String?

    public init(method: String, uri: URL, iv: Data? = nil, keyFormat: String? = nil) {
        self.method = method
        self.uri = uri
        self.iv = iv
        self.keyFormat = keyFormat
    }
}

public struct HLSInitMap: Sendable, Equatable {
    public let uri: URL
    public let byteRange: HLSByteRange?

    public init(uri: URL, byteRange: HLSByteRange? = nil) {
        self.uri = uri
        self.byteRange = byteRange
    }
}

public struct HLSSegmentInfo: Sendable {
    public let uri: URL
    public let duration: Double
    public let index: Int
    public let byteRange: HLSByteRange?
    public let keyInfo: HLSKeyInfo?
    public let initMap: HLSInitMap?
    /// Media sequence number của segment (EXT-X-MEDIA-SEQUENCE + index).
    /// Dùng làm IV mặc định cho AES-128 khi playlist không khai báo IV tường
    /// minh (RFC 8216 §4.3.2.2). `nil` với segment dựng tay → fallback `index`
    /// (hành vi cũ, A-F4).
    public let sequenceNumber: Int?

    public init(
        uri: URL,
        duration: Double,
        index: Int,
        byteRange: HLSByteRange? = nil,
        keyInfo: HLSKeyInfo? = nil,
        initMap: HLSInitMap? = nil,
        sequenceNumber: Int? = nil
    ) {
        self.uri = uri
        self.duration = duration
        self.index = index
        self.byteRange = byteRange
        self.keyInfo = keyInfo
        self.initMap = initMap
        self.sequenceNumber = sequenceNumber
    }
}

/// Một variant trong master playlist (`#EXT-X-STREAM-INF`).
public struct HLSVariant: Sendable, Equatable {
    public let uri: URL
    public let bandwidth: Int
    /// Giá trị `AUDIO="..."` — tên group audio tách rời mà variant này dùng.
    public let audioGroup: String?
    public let codecs: String?

    public init(uri: URL, bandwidth: Int, audioGroup: String? = nil, codecs: String? = nil) {
        self.uri = uri
        self.bandwidth = bandwidth
        self.audioGroup = audioGroup
        self.codecs = codecs
    }
}

/// Một rendition audio tách rời (`#EXT-X-MEDIA:TYPE=AUDIO`).
public struct HLSAudioRendition: Sendable, Equatable {
    public let uri: URL
    public let groupID: String
    public let name: String?
    public let isDefault: Bool
    public let isAutoselect: Bool

    public init(uri: URL, groupID: String, name: String? = nil, isDefault: Bool = false, isAutoselect: Bool = false) {
        self.uri = uri
        self.groupID = groupID
        self.name = name
        self.isDefault = isDefault
        self.isAutoselect = isAutoselect
    }
}

/// Master playlist đã phân tích: các variant video và các rendition audio tách rời.
public struct HLSMasterPlaylist: Sendable, Equatable {
    public let variants: [HLSVariant]
    public let audioRenditions: [HLSAudioRendition]

    public init(variants: [HLSVariant], audioRenditions: [HLSAudioRendition]) {
        self.variants = variants
        self.audioRenditions = audioRenditions
    }

    /// Variant chất lượng cao nhất (bandwidth lớn nhất).
    public var bestVariant: HLSVariant? {
        variants.max { $0.bandwidth < $1.bandwidth }
    }

    /// Rendition audio khớp đúng group mà variant tham chiếu.
    ///
    /// Trước đây code lấy `#EXT-X-MEDIA` audio đầu tiên bất kể group, nên với
    /// master nhiều group (nhiều ngôn ngữ/codec) dễ ghép sai hoặc ghép track
    /// không tương thích → file ra không có tiếng. Trả `nil` khi variant không
    /// khai báo `AUDIO` (audio đã nằm sẵn trong variant).
    public func audioRendition(for variant: HLSVariant) -> HLSAudioRendition? {
        guard let group = variant.audioGroup, !group.isEmpty else { return nil }
        let candidates = audioRenditions.filter { $0.groupID == group }
        guard !candidates.isEmpty else { return nil }
        return candidates.first(where: { $0.isDefault })
            ?? candidates.first(where: { $0.isAutoselect })
            ?? candidates.first
    }
}

/// Kết quả tải HLS — để `DownloadManager` biết nguồn có audio tách rời hay không.
public struct HLSDownloadResult: Sendable {
    public let destination: URL
    public let hadSeparateAudio: Bool
    public let audioMerged: Bool

    public init(destination: URL, hadSeparateAudio: Bool, audioMerged: Bool) {
        self.destination = destination
        self.hadSeparateAudio = hadSeparateAudio
        self.audioMerged = audioMerged
    }
}

/// Lỗi audio của HLS: nguồn khai báo có track tiếng nhưng không tải/ghép được.
public enum HLSAudioError: LocalizedError {
    case missingAudioTrack(String)
    case noMergeTool

    public var errorDescription: String? {
        switch self {
        case .missingAudioTrack(let reason):
            return "Nguồn tách âm thanh nhưng không tải/ghép được tiếng — sẽ không lưu video câm. Chi tiết: \(reason)"
        case .noMergeTool:
            return "Cần ffmpeg để ghép nhánh âm thanh tách rời của HLS. Cài ffmpeg rồi thử lại."
        }
    }
}

/// Lỗi tải/giải mã HLS có phân loại retry (dùng chung với RetryPolicy, A-F9/F10).
public enum HLSDownloadError: LocalizedError, Sendable {
    case unsupportedKeyMethod(String)
    case malformedKeyTag(String)
    case truncatedRangeBody(expected: Int64, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedKeyMethod(let method):
            return "Playlist HLS dùng phương thức mã hóa không hỗ trợ: \(method) — chỉ hỗ trợ AES-128 (SAMPLE-AES/AES-256 cần trình giải mã khác, METHOD=NONE không được kèm URI/IV)."
        case .malformedKeyTag(let detail):
            return "Thẻ EXT-X-KEY không hợp lệ: \(detail)"
        case .truncatedRangeBody(let expected, let actual):
            return "Server bỏ qua Range và trả body ngắn hơn cửa sổ byterange (nhận \(actual)/cần \(expected) byte) — sẽ thử lại."
        }
    }

    /// Chỉ body cụt là retry được (mạng/server chập chờn); sai phương thức mã
    /// hóa retry cũng không cứu được → fail nhanh.
    public var isRetryable: Bool {
        switch self {
        case .truncatedRangeBody: return true
        case .unsupportedKeyMethod, .malformedKeyTag: return false
        }
    }
}

public actor HLSDownloader {
    private let session: URLSession
    private let speedTracker = SpeedTracker()
    private var isCancelled = false
    private var keyCache: [URL: Data] = [:]

    public init(session: URLSession = HTTPRangeDownloader.makeOptimizedSession()) {
        self.session = session
    }

    public static func parsePlaylist(content: String, baseURL: URL) throws -> [HLSSegmentInfo] {
        if content.contains("#EXT-X-STREAM-INF") {
            return []
        }

        var segments: [HLSSegmentInfo] = []
        let lines = content.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }

        var currentDuration: Double = 0.0
        var segmentIndex = 0
        var currentByteRange: HLSByteRange? = nil
        var lastByteRangeEnd: Int64 = 0
        var currentKeyInfo: HLSKeyInfo? = nil
        var currentInitMap: HLSInitMap? = nil
        // A-F4: EXT-X-MEDIA-SEQUENCE (default 0) — IV mặc định phải dùng media
        // sequence number, không phải index bắt đầu từ 0 trong playlist.
        var mediaSequenceBase = 0

        for line in lines {
            if line.isEmpty { continue }

            if line.hasPrefix("#EXTINF:") {
                let durationStr = line.dropFirst("#EXTINF:".count).split(separator: ",")[0]
                currentDuration = Double(durationStr) ?? 0.0
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                let seqStr = String(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)).trimmingCharacters(in: .whitespaces)
                mediaSequenceBase = max(0, Int(seqStr) ?? 0)
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                let rangeStr = String(line.dropFirst("#EXT-X-BYTERANGE:".count)).trimmingCharacters(in: .whitespaces)
                let parts = rangeStr.split(separator: "@")
                if let len = Int64(parts[0]) {
                    let off: Int64
                    if parts.count > 1, let parsedOff = Int64(parts[1]) {
                        off = parsedOff
                    } else {
                        off = lastByteRangeEnd
                    }
                    currentByteRange = HLSByteRange(length: len, offset: off)
                    lastByteRangeEnd = off + len
                }
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let keyStr = String(line.dropFirst("#EXT-X-KEY:".count))
                currentKeyInfo = try parseKeyTag(keyStr, baseURL: baseURL)
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let mapStr = String(line.dropFirst("#EXT-X-MAP:".count))
                currentInitMap = parseMapTag(mapStr, baseURL: baseURL)
            } else if !line.hasPrefix("#") {
                let segmentURL: URL
                if line.lowercased().hasPrefix("http://") || line.lowercased().hasPrefix("https://") {
                    segmentURL = URL(string: line) ?? baseURL
                } else {
                    segmentURL = URL(string: line, relativeTo: baseURL)?.absoluteURL ?? baseURL
                }
                segments.append(HLSSegmentInfo(
                    uri: segmentURL,
                    duration: currentDuration,
                    index: segmentIndex,
                    byteRange: currentByteRange,
                    keyInfo: currentKeyInfo,
                    initMap: currentInitMap,
                    sequenceNumber: mediaSequenceBase + segmentIndex
                ))
                segmentIndex += 1
                currentByteRange = nil
            }
        }

        return segments
    }

    /// Phân tích master playlist: variant video + rendition audio tách rời.
    ///
    /// Ghép đúng `EXT-X-MEDIA` theo `GROUP-ID` mà variant tham chiếu qua thuộc
    /// tính `AUDIO`, thay vì lấy rendition audio đầu tiên trong file.
    public static func parseMasterPlaylist(content: String, baseURL: URL) -> HLSMasterPlaylist {
        let lines = content.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var variants: [HLSVariant] = []
        var renditions: [HLSAudioRendition] = []

        for index in lines.indices {
            let line = lines[index]
            if line.hasPrefix("#EXT-X-MEDIA:") {
                let attrs = parseAttributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                guard (attrs["TYPE"] ?? "").uppercased() == "AUDIO",
                      let groupID = attrs["GROUP-ID"], !groupID.isEmpty,
                      let uriStr = attrs["URI"], !uriStr.isEmpty else { continue }
                let resolved: URL?
                if uriStr.lowercased().hasPrefix("http://") || uriStr.lowercased().hasPrefix("https://") {
                    resolved = URL(string: uriStr)
                } else {
                    resolved = URL(string: uriStr, relativeTo: baseURL)?.absoluteURL
                }
                guard let uri = resolved else { continue }
                renditions.append(HLSAudioRendition(
                    uri: uri,
                    groupID: groupID,
                    name: attrs["NAME"],
                    isDefault: (attrs["DEFAULT"] ?? "").uppercased() == "YES",
                    isAutoselect: (attrs["AUTOSELECT"] ?? "").uppercased() == "YES"
                ))
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attrs = parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                guard let next = lines.indices.first(where: { $0 > index && !lines[$0].isEmpty && !lines[$0].hasPrefix("#") }) else {
                    continue
                }
                let uriString = lines[next]
                let uri: URL?
                if uriString.lowercased().hasPrefix("http://") || uriString.lowercased().hasPrefix("https://") {
                    uri = URL(string: uriString)
                } else {
                    uri = URL(string: uriString, relativeTo: baseURL)?.absoluteURL
                }
                guard let variantURI = uri else { continue }
                let bandwidth = Int(attrs["BANDWIDTH"] ?? "") ?? 0
                variants.append(HLSVariant(
                    uri: variantURI,
                    bandwidth: bandwidth,
                    audioGroup: attrs["AUDIO"],
                    codecs: attrs["CODECS"]
                ))
            }
        }

        return HLSMasterPlaylist(variants: variants, audioRenditions: renditions)
    }

    /// Phân tích thẻ EXT-X-KEY (A-F5: chỉ chấp nhận METHOD=AES-128).
    ///
    /// - Trả `nil` khi `METHOD=NONE` hợp lệ (không mã hóa) hoặc thiếu METHOD.
    /// - Throw `HLSDownloadError` khi METHOD là SAMPLE-AES/AES-256… (trước đây
    ///   nhận mọi METHOD rồi decrypt AES-128-CBC → rác không báo lỗi), hoặc
    ///   METHOD=NONE nhưng kèm URI/IV trái RFC 8216.
    public static func parseKeyTag(_ tag: String, baseURL: URL) throws -> HLSKeyInfo? {
        let attrs = parseAttributes(tag)
        guard let method = attrs["METHOD"] else { return nil }
        let upperMethod = method.uppercased()
        if upperMethod == "NONE" {
            if attrs["URI"] != nil || attrs["IV"] != nil {
                throw HLSDownloadError.malformedKeyTag("METHOD=NONE không được kèm URI/IV")
            }
            return nil
        }
        guard upperMethod == "AES-128" else {
            throw HLSDownloadError.unsupportedKeyMethod(method)
        }
        // KEYFORMAT="identity" nghĩa là không mã hóa (RFC 8216) → không cần key.
        if (attrs["KEYFORMAT"] ?? "").uppercased() == "IDENTITY" { return nil }
        guard let uriStr = attrs["URI"], !uriStr.isEmpty else {
            throw HLSDownloadError.malformedKeyTag("METHOD=AES-128 thiếu URI của key")
        }
        let resolvedURL: URL
        if uriStr.lowercased().hasPrefix("http://") || uriStr.lowercased().hasPrefix("https://") {
            resolvedURL = URL(string: uriStr) ?? baseURL
        } else {
            resolvedURL = URL(string: uriStr, relativeTo: baseURL)?.absoluteURL ?? baseURL
        }
        var ivData: Data? = nil
        if let ivStr = attrs["IV"] {
            let cleanHex = ivStr.lowercased().replacingOccurrences(of: "0x", with: "")
            if cleanHex.count == 32 {
                var data = Data()
                var idx = cleanHex.startIndex
                while idx < cleanHex.endIndex {
                    let nextIdx = cleanHex.index(idx, offsetBy: 2)
                    let byteStr = cleanHex[idx..<nextIdx]
                    if let byte = UInt8(byteStr, radix: 16) {
                        data.append(byte)
                    }
                    idx = nextIdx
                }
                if data.count == 16 {
                    ivData = data
                }
            }
        }
        return HLSKeyInfo(method: method, uri: resolvedURL, iv: ivData, keyFormat: attrs["KEYFORMAT"])
    }

    public static func parseMapTag(_ tag: String, baseURL: URL) -> HLSInitMap? {
        let attrs = parseAttributes(tag)
        guard let uriStr = attrs["URI"], !uriStr.isEmpty else { return nil }
        let resolvedURL: URL
        if uriStr.lowercased().hasPrefix("http://") || uriStr.lowercased().hasPrefix("https://") {
            resolvedURL = URL(string: uriStr) ?? baseURL
        } else {
            resolvedURL = URL(string: uriStr, relativeTo: baseURL)?.absoluteURL ?? baseURL
        }
        var byteRange: HLSByteRange? = nil
        if let brStr = attrs["BYTERANGE"] {
            let parts = brStr.split(separator: "@")
            if let len = Int64(parts[0]) {
                let off = parts.count > 1 ? (Int64(parts[1]) ?? 0) : 0
                byteRange = HLSByteRange(length: len, offset: off)
            }
        }
        return HLSInitMap(uri: resolvedURL, byteRange: byteRange)
    }

    public static func parseAttributes(_ line: String) -> [String: String] {
        var result: [String: String] = [:]
        var index = line.startIndex
        while index < line.endIndex {
            while index < line.endIndex && (line[index] == "," || line[index] == " ") {
                index = line.index(after: index)
            }
            if index >= line.endIndex { break }
            guard let equalIdx = line[index...].firstIndex(of: "=") else { break }
            let key = String(line[index..<equalIdx]).trimmingCharacters(in: .whitespaces)
            var valStart = line.index(after: equalIdx)
            if valStart < line.endIndex && line[valStart] == "\"" {
                valStart = line.index(after: valStart)
                let valEnd = line[valStart...].firstIndex(of: "\"") ?? line.endIndex
                result[key] = String(line[valStart..<valEnd])
                index = valEnd < line.endIndex ? line.index(after: valEnd) : valEnd
            } else {
                let valEnd = line[valStart...].firstIndex(where: { $0 == "," || $0 == "\n" || $0 == "\r" }) ?? line.endIndex
                result[key] = String(line[valStart..<valEnd]).trimmingCharacters(in: .whitespaces)
                index = valEnd
            }
        }
        return result
    }

    public static func makeDefaultIV(sequenceNumber: Int) -> Data {
        var iv = Data(repeating: 0, count: 16)
        var bigSeq = UInt64(sequenceNumber).bigEndian
        withUnsafeBytes(of: &bigSeq) { bytes in
            iv.replaceSubrange(8..<16, with: bytes)
        }
        return iv
    }

    /// Ước độ dài segment từ duration × bandwidth (A-F8). Trả -1 (unknown) khi
    /// thiếu dữ liệu — caller HEAD 1 lần để xác minh thay vì đoán mò.
    static func estimateSegmentLength(duration: Double, bandwidth: Int) -> Int64 {
        guard duration > 0, bandwidth > 0 else { return -1 }
        let bytes = duration * Double(bandwidth) / 8.0
        guard bytes.isFinite, bytes > 0, bytes < Double(Int64.max) else { return -1 }
        return Int64(bytes)
    }

    public static func decryptAES128(data: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == 16 else {
            throw NSError(domain: "HLSDownloader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid AES-128 key length (\(key.count))"])
        }
        guard iv.count == 16 else {
            throw NSError(domain: "HLSDownloader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid AES-128 IV length (\(iv.count))"])
        }
        var decryptedData = Data(count: data.count + kCCBlockSizeAES128)
        var numBytesDecrypted: size_t = 0
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                data.withUnsafeBytes { dataBytes in
                    decryptedData.withUnsafeMutableBytes { outBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, kCCKeySizeAES128,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress, data.count,
                            outBytes.baseAddress, outBytes.count,
                            &numBytesDecrypted
                        )
                    }
                }
            }
        }
        if status == kCCSuccess {
            decryptedData.removeSubrange(numBytesDecrypted..<decryptedData.count)
            return decryptedData
        }

        var noPadDecrypted = Data(count: data.count + kCCBlockSizeAES128)
        var noPadBytes: size_t = 0
        let statusNoPad = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                data.withUnsafeBytes { dataBytes in
                    noPadDecrypted.withUnsafeMutableBytes { outBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            0,
                            keyBytes.baseAddress, kCCKeySizeAES128,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress, data.count,
                            outBytes.baseAddress, outBytes.count,
                            &noPadBytes
                        )
                    }
                }
            }
        }
        guard statusNoPad == kCCSuccess else {
            throw NSError(domain: "HLSDownloader", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "AES-128 decryption failed with status \(status)"])
        }
        noPadDecrypted.removeSubrange(noPadBytes..<noPadDecrypted.count)
        return noPadDecrypted
    }

    /// Tải một playlist HLS (media hoặc master) thành file media hoàn chỉnh.
    ///
    /// Nếu master có nhánh audio tách rời (`EXT-X-MEDIA`), nhánh audio được tải
    /// và ghép bằng ffmpeg. **Không bao giờ** trả về file video-only trong trường
    /// hợp nhánh audio được khai báo nhưng tải/ghép thất bại — khi đó ném
    /// `HLSAudioError` để task báo lỗi rõ ràng thay vì "thành công" với file câm.
    @discardableResult
    public func download(
        playlistURL: URL,
        destinationFile: URL,
        tempDirectory: URL,
        taskId: UUID = UUID(),
        maxConcurrency: Int = 4,
        cookies: String? = nil,
        referrer: String? = nil,
        userAgent: String? = nil,
        customHeaders: [String: String]? = nil,
        onProgress: @escaping @Sendable (
            _ downloadedSegments: Int,
            _ totalSegments: Int,
            _ downloadedBytes: Int64,
            _ estimatedTotalBytes: Int64,
            _ speed: Double,
            _ activeSegments: [DownloadSegment]
        ) -> Void
    ) async throws -> HLSDownloadResult {
        isCancelled = false
        speedTracker.reset()

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: tempDirectory.path) {
            try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        }

        let effectiveUA = userAgent ?? URLNormalizer.defaultUserAgent
        var effectiveReferer: String? = referrer ?? (playlistURL.host.map { "https://\($0)/" } ?? playlistURL.absoluteString)

        // 1. Fetch playlist content with referer fallback
        let (playlistData, workingReferer) = try await fetchPlaylistDataWithRefererFallback(
            url: playlistURL,
            initialReferer: effectiveReferer,
            userAgent: effectiveUA,
            cookies: cookies,
            customHeaders: customHeaders
        )
        effectiveReferer = workingReferer

        guard let playlistString = String(data: playlistData, encoding: .utf8), playlistString.contains("#EXT") else {
            throw URLError(.cannotDecodeContentData)
        }

        var segments = try Self.parsePlaylist(content: playlistString, baseURL: playlistURL)
        var separateAudioURL: URL? = nil
        var chosenBandwidth = 0

        // Master playlist → chọn variant chất lượng cao nhất và rendition audio
        // thuộc đúng AUDIO group của variant đó.
        if segments.isEmpty && playlistString.contains("#EXT-X-STREAM-INF") {
            let master = Self.parseMasterPlaylist(content: playlistString, baseURL: playlistURL)
            for variant in master.variants.sorted(by: { $0.bandwidth > $1.bandwidth }) {
                guard let (childData, childWorkingRef) = try? await fetchPlaylistDataWithRefererFallback(
                    url: variant.uri,
                    initialReferer: effectiveReferer,
                    userAgent: effectiveUA,
                    cookies: cookies,
                    customHeaders: customHeaders
                ),
                let childStr = String(data: childData, encoding: .utf8) else { continue }
                let parsed = try Self.parsePlaylist(content: childStr, baseURL: variant.uri)
                if !parsed.isEmpty {
                    segments = parsed
                    effectiveReferer = childWorkingRef
                    separateAudioURL = master.audioRendition(for: variant)?.uri
                    chosenBandwidth = variant.bandwidth
                    break
                }
            }
        }

        guard !segments.isEmpty else {
            throw NSError(domain: "HLSDownloader", code: 1, userInfo: [NSLocalizedDescriptionKey: "No media segments found in playlist"])
        }

        // A-F8: độ dài kỳ vọng mỗi segment để resume kiểm chứng thay vì chỉ
        // check size > 0 (segment cụt từng bị coi là xong → concat hỏng):
        // byterange → chính xác; master có bandwidth → ước duration*bandwidth/8;
        // còn lại unknown (-1) → HEAD 1 lần lấy Content-Length khi cần.
        var expectedByIndex: [Int: Int64] = [:]
        for seg in segments {
            if let br = seg.byteRange, br.length > 0 {
                expectedByIndex[seg.index] = br.length
            } else {
                expectedByIndex[seg.index] = Self.estimateSegmentLength(duration: seg.duration, bandwidth: chosenBandwidth)
            }
        }

        /// HEAD 1 lần duy nhất để biết Content-Length khi expectedLen unknown
        /// (không retry trong probe — fail thì segment đó tải lại cho chắc).
        func probeSegmentLength(_ url: URL) async -> Int64? {
            var req = URLRequest(url: url)
            req.httpMethod = "HEAD"
            req.timeoutInterval = 15
            req.setValue(effectiveUA, forHTTPHeaderField: "User-Agent")
            if let r = effectiveReferer { req.setValue(r, forHTTPHeaderField: "Referer") }
            if let c = cookies, !c.isEmpty { req.setValue(c, forHTTPHeaderField: "Cookie") }
            if let headers = customHeaders {
                for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            }
            do {
                let (_, response) = try await session.data(for: req)
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode) else { return nil }
                if let lenStr = http.value(forHTTPHeaderField: "Content-Length"),
                   let len = Int64(lenStr), len > 0 { return len }
                if http.expectedContentLength > 0 { return http.expectedContentLength }
                return nil
            } catch {
                log.warning("HLS resume HEAD probe failed for \(url.absoluteString): \(error.localizedDescription)")
                return nil
            }
        }

        /// Segment coi là đã tải xong chỉ khi size>0 && size==expectedLen.
        /// Lưu ý: segment mã hóa (AES-128) lưu plaintext sau decrypt nên size
        /// đĩa không khớp Content-Length/ciphertext → luôn tải lại cho chắc.
        func isSegmentComplete(_ seg: HLSSegmentInfo) async -> Bool {
            let dest = tempDirectory.appendingPathComponent(String(format: "hls_seg_%05d.ts", seg.index))
            guard fileManager.fileExists(atPath: dest.path),
                  let attrs = try? fileManager.attributesOfItem(atPath: dest.path),
                  let size = attrs[.size] as? Int64, size > 0 else { return false }
            if let expected = expectedByIndex[seg.index], expected > 0 {
                return size == expected
            }
            guard seg.keyInfo == nil else { return false }
            guard let probed = await probeSegmentLength(seg.uri), probed > 0 else { return false }
            expectedByIndex[seg.index] = probed
            return size == probed
        }

        // If fMP4 / CMAF init segment is specified, download it first
        let initFile = tempDirectory.appendingPathComponent("init_segment.mp4")
        if let initMap = segments.compactMap({ $0.initMap }).first {
            if !fileManager.fileExists(atPath: initFile.path) {
                _ = try await downloadSingleSegmentWithRetry(
                    from: initMap.uri,
                    to: initFile,
                    byteRange: initMap.byteRange,
                    keyData: nil,
                    iv: nil,
                    referer: effectiveReferer,
                    cookies: cookies,
                    userAgent: effectiveUA,
                    customHeaders: customHeaders
                )
            }
        }

        let totalSegments = segments.count
        var downloadedCount = 0
        var downloadedBytesTotal: Int64 = 0

        let partFiles = segments.map { tempDirectory.appendingPathComponent(String(format: "hls_seg_%05d.ts", $0.index)) }

        let concurrency = max(1, min(maxConcurrency, segments.count))
        var activeSegments: [DownloadSegment] = (0..<concurrency).map { slot in
            DownloadSegment(
                id: UUID(),
                taskId: taskId,
                index: slot,
                startByte: 0,
                endByte: 100,
                downloadedBytes: 0,
                status: .pending
            )
        }

        // Pre-scan already downloaded parts for resume capability (A-F8: strict).
        for seg in segments {
            if await isSegmentComplete(seg) {
                downloadedCount += 1
                let dest = partFiles[seg.index]
                if let attrs = try? fileManager.attributesOfItem(atPath: dest.path),
                   let size = attrs[.size] as? Int64 {
                    downloadedBytesTotal += size
                }
            }
        }

        var nextSegmentIdx = 0
        func advanceToNextUnfinishedSegment() async -> HLSSegmentInfo? {
            while nextSegmentIdx < segments.count {
                let seg = segments[nextSegmentIdx]
                nextSegmentIdx += 1
                if await isSegmentComplete(seg) {
                    continue
                }
                return seg
            }
            return nil
        }

        try await withThrowingTaskGroup(of: (slotIndex: Int, segmentIndex: Int, bytesCount: Int64).self) { group in
            for slot in 0..<concurrency {
                guard !isCancelled, let seg = await advanceToNextUnfinishedSegment() else { break }
                let dest = partFiles[seg.index]
                let currentSlot = slot
                activeSegments[currentSlot].status = .downloading
                activeSegments[currentSlot].downloadedBytes = 0

                let keyData: Data?
                let ivData: Data?
                if let kInfo = seg.keyInfo {
                    keyData = try await self.getKeyDataWithRetry(
                        uri: kInfo.uri,
                        referer: effectiveReferer,
                        cookies: cookies,
                        userAgent: effectiveUA,
                        customHeaders: customHeaders
                    )
                    ivData = kInfo.iv ?? Self.makeDefaultIV(sequenceNumber: seg.sequenceNumber ?? seg.index)
                } else {
                    keyData = nil
                    ivData = nil
                }

                group.addTask { [self] in
                    let bytesCount = try await self.downloadSingleSegmentWithRetry(
                        from: seg.uri,
                        to: dest,
                        byteRange: seg.byteRange,
                        keyData: keyData,
                        iv: ivData,
                        referer: effectiveReferer,
                        cookies: cookies,
                        userAgent: effectiveUA,
                        customHeaders: customHeaders
                    )
                    return (currentSlot, seg.index, bytesCount)
                }
            }

            let initialEst = downloadedCount > 0 ? (downloadedBytesTotal / Int64(downloadedCount)) * Int64(totalSegments) : 0
            onProgress(downloadedCount, totalSegments, downloadedBytesTotal, initialEst, 0, activeSegments)

            for try await (slotIndex, _, bytesCount) in group {
                if isCancelled || Task.isCancelled {
                    group.cancelAll()
                    throw CancellationError()
                }
                downloadedCount += 1
                downloadedBytesTotal += bytesCount
                speedTracker.record(bytes: bytesCount)
                let speed = speedTracker.currentSpeed()
                let estimatedTotal = downloadedCount > 0 ? (downloadedBytesTotal / Int64(downloadedCount)) * Int64(totalSegments) : 0

                activeSegments[slotIndex].status = .completed
                activeSegments[slotIndex].downloadedBytes = activeSegments[slotIndex].expectedBytes

                onProgress(downloadedCount, totalSegments, downloadedBytesTotal, estimatedTotal, speed, activeSegments)

                if !isCancelled && !Task.isCancelled, let nextSeg = await advanceToNextUnfinishedSegment() {
                    let dest = partFiles[nextSeg.index]
                    let currentSlot = slotIndex
                    activeSegments[currentSlot].status = .downloading
                    activeSegments[currentSlot].downloadedBytes = 0

                    let keyData: Data?
                    let ivData: Data?
                    if let kInfo = nextSeg.keyInfo {
                        keyData = try await self.getKeyDataWithRetry(
                            uri: kInfo.uri,
                            referer: effectiveReferer,
                            cookies: cookies,
                            userAgent: effectiveUA,
                            customHeaders: customHeaders
                        )
                        ivData = kInfo.iv ?? Self.makeDefaultIV(sequenceNumber: nextSeg.sequenceNumber ?? nextSeg.index)
                    } else {
                        keyData = nil
                        ivData = nil
                    }

                    group.addTask { [self] in
                        let bytesCount = try await self.downloadSingleSegmentWithRetry(
                            from: nextSeg.uri,
                            to: dest,
                            byteRange: nextSeg.byteRange,
                            keyData: keyData,
                            iv: ivData,
                            referer: effectiveReferer,
                            cookies: cookies,
                            userAgent: effectiveUA,
                            customHeaders: customHeaders
                        )
                        return (currentSlot, nextSeg.index, bytesCount)
                    }
                }
            }
        }

        if isCancelled || Task.isCancelled {
            throw CancellationError()
        }

        // Concatenate all downloaded segments
        let rawConcatFile = tempDirectory.appendingPathComponent("raw_concat.ts")
        fileManager.createFile(atPath: rawConcatFile.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: rawConcatFile)

        // Prepend init segment if fMP4
        if fileManager.fileExists(atPath: initFile.path),
           let inInit = try? FileHandle(forReadingFrom: initFile) {
            while let data = try inInit.read(upToCount: 512 * 1024), !data.isEmpty {
                try outHandle.write(contentsOf: data)
            }
            try? inInit.close()
        }

        for partFile in partFiles {
            guard fileManager.fileExists(atPath: partFile.path) else { continue }
            let inHandle = try FileHandle(forReadingFrom: partFile)
            while let data = try inHandle.read(upToCount: 512 * 1024), !data.isEmpty {
                try outHandle.write(contentsOf: data)
            }
            try? inHandle.close()
        }
        try? outHandle.close()

        // HLS luôn là container video; nếu đuôi người dùng nhập không phải
        // container hợp lệ thì đổi sang .mp4 (ffmpeg mới suy ra được muxer).
        var finalDestination = destinationFile
        let supportedContainerExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "webm", "ts"]
        if !supportedContainerExtensions.contains(finalDestination.pathExtension.lowercased()) {
            let base = finalDestination.deletingPathExtension().lastPathComponent
            finalDestination = finalDestination.deletingLastPathComponent()
                .appendingPathComponent("\(base.isEmpty ? "video" : base).mp4")
        }

        let targetDir = finalDestination.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: targetDir.path) {
            try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
        }
        if fileManager.fileExists(atPath: finalDestination.path) {
            try fileManager.removeItem(at: finalDestination)
        }

        // Nếu variant đã chứa audio sẵn thì không ghép thêm track ngoài (tránh 2 track).
        let variantHasAudio = MediaIntegrity.report(of: rawConcatFile)?.hasAudio ?? false

        var audioConcatFile: URL? = nil
        if let audioURL = separateAudioURL, !variantHasAudio {
            let audioTempDir = tempDirectory.appendingPathComponent("audio_stream")
            let audioDest = tempDirectory.appendingPathComponent("audio_concat.ts")
            let audioDownloader = HLSDownloader(session: session)
            do {
                _ = try await audioDownloader.download(
                    playlistURL: audioURL,
                    destinationFile: audioDest,
                    tempDirectory: audioTempDir,
                    taskId: taskId,
                    maxConcurrency: 2,
                    cookies: cookies,
                    referrer: effectiveReferer,
                    userAgent: effectiveUA,
                    customHeaders: customHeaders,
                    onProgress: { _, _, _, _, _, _ in }
                )
                if fileManager.fileExists(atPath: audioDest.path) {
                    audioConcatFile = audioDest
                } else {
                    log.error("HLS: audio playlist tải xong nhưng không có file \(audioDest.lastPathComponent)")
                }
            } catch {
                // Không bỏ qua im lặng: publish video-only = người dùng mất tiếng
                // mà không được báo. Ném lỗi để task hiện "thất bại" kèm lý do.
                log.error("HLS: tải nhánh audio riêng thất bại (\(audioURL.absoluteString)): \(error.localizedDescription)")
                throw HLSAudioError.missingAudioTrack(error.localizedDescription)
            }
        }

        let mustMergeAudio = !variantHasAudio && audioConcatFile != nil
        var remuxed = false
        if mustMergeAudio {
            guard let ffmpeg = MediaURLResolver.findFfmpegBinary() else {
                throw HLSAudioError.noMergeTool
            }
            guard let audioFile = audioConcatFile else {
                throw HLSAudioError.missingAudioTrack("không có file audio sau khi tải")
            }
            remuxed = Self.runFFmpegRemux(ffmpeg: ffmpeg, video: rawConcatFile, audio: audioFile, output: finalDestination)
            guard remuxed else {
                try? fileManager.removeItem(at: finalDestination)
                throw HLSAudioError.missingAudioTrack("ffmpeg không ghép được nhánh audio tách rời")
            }
        } else if finalDestination.pathExtension.lowercased() != "ts",
                  let ffmpeg = MediaURLResolver.findFfmpegBinary() {
            // Không có audio tách rời: chỉ đổi container (TS/fMP4 → mp4/mkv).
            remuxed = Self.runFFmpegRemux(ffmpeg: ffmpeg, video: rawConcatFile, audio: nil, output: finalDestination)
        }

        if !remuxed {
            try fileManager.moveItem(at: rawConcatFile, to: finalDestination)
        }

        try? fileManager.removeItem(at: tempDirectory)
        return HLSDownloadResult(
            destination: finalDestination,
            hadSeparateAudio: separateAudioURL != nil,
            audioMerged: mustMergeAudio && remuxed
        )
    }

    /// Remux bằng ffmpeg: video luôn copy; audio (nếu có) thử copy trước rồi mới
    /// transcode sang codec hợp container.
    private static func runFFmpegRemux(ffmpeg: String, video: URL, audio: URL?, output: URL) -> Bool {
        let outputExt = output.pathExtension.lowercased()
        func run(audioArguments: [String]) -> Bool {
            try? FileManager.default.removeItem(at: output)
            var arguments = ["-y", "-nostdin", "-i", video.path]
            if let audio {
                arguments += ["-i", audio.path, "-map", "0:v:0", "-map", "1:a:0"]
            }
            arguments += ["-c:v", "copy"]
            if audio != nil {
                arguments += audioArguments
            } else {
                arguments += ["-c:a", "copy"]
            }
            if ["mp4", "mov", "m4v"].contains(outputExt) {
                arguments += ["-movflags", "+faststart"]
            }
            arguments.append(output.path)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            let errorPipe = Pipe()
            process.standardError = errorPipe
            guard (try? process.run()) != nil else { return false }
            _ = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize), size > 0 else {
                return false
            }
            return true
        }

        let copyArgs = ["-c:a", "copy"]
        let transcodeArgs: [String]
        switch outputExt {
        case "mp4", "mov", "m4v":
            transcodeArgs = ["-c:a", "aac", "-b:a", "192k"]
        case "webm":
            transcodeArgs = ["-c:a", "libopus", "-b:a", "160k"]
        default:
            transcodeArgs = ["-c:a", "aac", "-b:a", "192k"]
        }
        if run(audioArguments: copyArgs) { return true }
        return run(audioArguments: transcodeArgs)
    }

    /// A-F9: bọc getKeyData bằng retry dùng chung RetryPolicy (tôn trọng
    /// Retry-After). Lỗi key/mã hóa (HLSDownloadError non-retryable) fail ngay.
    private func getKeyDataWithRetry(
        uri: URL,
        referer: String?,
        cookies: String?,
        userAgent: String?,
        customHeaders: [String: String]?
    ) async throws -> Data {
        var attempt = 0
        while true {
            do {
                return try await getKeyData(
                    uri: uri,
                    referer: referer,
                    cookies: cookies,
                    userAgent: userAgent,
                    customHeaders: customHeaders
                )
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw error
                }
                guard RetryPolicy.shouldRetry(failedAttempt: attempt, error: error) else {
                    throw error
                }
                let retryAfter = (error as NSError).userInfo["retryAfter"] as? String
                let delay = RetryPolicy.retryDelay(attempt: attempt, retryAfterHeader: retryAfter) ?? 1.0
                attempt += 1
                log.warning("HLS key fetch failed (\(uri.absoluteString)): \(error.localizedDescription) — retrying (\(attempt)/\(RetryPolicy.maxAttempts)) after \(delay)s")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { throw CancellationError() }
            }
        }
    }

    private func getKeyData(
        uri: URL,
        referer: String?,
        cookies: String?,
        userAgent: String?,
        customHeaders: [String: String]?
    ) async throws -> Data {
        if let cached = keyCache[uri] { return cached }
        let (data, _) = try await fetchPlaylistDataWithRefererFallback(
            url: uri,
            initialReferer: referer,
            userAgent: userAgent ?? URLNormalizer.defaultUserAgent,
            cookies: cookies,
            customHeaders: customHeaders
        )
        guard data.count == 16 else {
            throw NSError(domain: "HLSDownloader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid key size from \(uri) (\(data.count) bytes)"])
        }
        keyCache[uri] = data
        return data
    }

    private func fetchPlaylistDataWithRefererFallback(
        url: URL,
        initialReferer: String?,
        userAgent: String,
        cookies: String?,
        customHeaders: [String: String]? = nil
    ) async throws -> (Data, String?) {
        var candidateReferers: [String?] = []
        if let initial = initialReferer {
            candidateReferers.append(initial)
        }
        let originRef = url.host.map { "https://\($0)/" }
        if let originRef = originRef, !candidateReferers.contains(originRef) {
            candidateReferers.append(originRef)
        }
        let lastComp = url.lastPathComponent.lowercased()
        if lastComp.hasPrefix("index") && lastComp.hasSuffix(".m3u8") {
            let masterRef = url.deletingLastPathComponent().appendingPathComponent("master.m3u8").absoluteString
            if !candidateReferers.contains(masterRef) {
                candidateReferers.append(masterRef)
            }
        }
        let parentRef = url.deletingLastPathComponent().absoluteString
        if !candidateReferers.contains(parentRef) {
            candidateReferers.append(parentRef)
        }
        if !candidateReferers.contains(nil) {
            candidateReferers.append(nil)
        }

        var lastError: Error?
        let cookieAttempts: [String?] = (cookies?.isEmpty == false) ? [cookies, nil] : [nil]

        for cookieOpt in cookieAttempts {
            for candidate in candidateReferers {
                var req = URLRequest(url: url)
                req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                req.setValue("*/*", forHTTPHeaderField: "Accept")
                // Chỉ gzip: URLSession tự giải gzip, còn brotli không — nếu xin
                // br thì CDN (Cloudflare) trả brotli và playlist String(data:) fail.
                req.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
                if let r = candidate {
                    req.setValue(r, forHTTPHeaderField: "Referer")
                }
                if let c = cookieOpt, !c.isEmpty {
                    req.setValue(c, forHTTPHeaderField: "Cookie")
                }
                if let headers = customHeaders {
                    for (k, v) in headers {
                        req.setValue(v, forHTTPHeaderField: k)
                    }
                }

                do {
                    let (data, response) = try await session.data(for: req)
                    guard let httpResp = response as? HTTPURLResponse else {
                        throw URLError(.badServerResponse)
                    }
                    if (200...299).contains(httpResp.statusCode) {
                        return (data, candidate)
                    }
                    lastError = NSError(domain: "HLSDownloader", code: httpResp.statusCode, userInfo: [
                        NSLocalizedDescriptionKey: "Playlist HTTP \(httpResp.statusCode)"
                    ])
                    if httpResp.statusCode != 403 {
                        break
                    }
                } catch {
                    lastError = error
                }
            }
        }
        throw lastError ?? URLError(.badServerResponse)
    }

    /// A-F9: bọc downloadSingleSegment bằng retry dùng chung RetryPolicy
    /// (tôn trọng Retry-After). Vòng lặp referer/cookie bên trong giữ nguyên;
    /// chỉ bọc ngoài cùng để lỗi mạng/5xx/429/408/body-cụt được thử lại.
    private func downloadSingleSegmentWithRetry(
        from url: URL,
        to destination: URL,
        byteRange: HLSByteRange? = nil,
        keyData: Data? = nil,
        iv: Data? = nil,
        referer: String?,
        cookies: String?,
        userAgent: String?,
        customHeaders: [String: String]? = nil
    ) async throws -> Int64 {
        var attempt = 0
        while true {
            do {
                return try await downloadSingleSegment(
                    from: url,
                    to: destination,
                    byteRange: byteRange,
                    keyData: keyData,
                    iv: iv,
                    referer: referer,
                    cookies: cookies,
                    userAgent: userAgent,
                    customHeaders: customHeaders
                )
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw error
                }
                guard RetryPolicy.shouldRetry(failedAttempt: attempt, error: error) else {
                    throw error
                }
                let retryAfter = (error as NSError).userInfo["retryAfter"] as? String
                let delay = RetryPolicy.retryDelay(attempt: attempt, retryAfterHeader: retryAfter) ?? 1.0
                attempt += 1
                log.warning("HLS segment failed (\(url.absoluteString)): \(error.localizedDescription) — retrying (\(attempt)/\(RetryPolicy.maxAttempts)) after \(delay)s")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { throw CancellationError() }
            }
        }
    }

    private func downloadSingleSegment(
        from url: URL,
        to destination: URL,
        byteRange: HLSByteRange? = nil,
        keyData: Data? = nil,
        iv: Data? = nil,
        referer: String?,
        cookies: String?,
        userAgent: String?,
        customHeaders: [String: String]? = nil
    ) async throws -> Int64 {
        var candidateReferers: [String?] = []
        if let referer = referer {
            candidateReferers.append(referer)
        }
        let originRef = url.host.map { "https://\($0)/" }
        if let originRef = originRef, !candidateReferers.contains(originRef) {
            candidateReferers.append(originRef)
        }
        if !candidateReferers.contains(nil) {
            candidateReferers.append(nil)
        }

        // A-F20: guard let thay `cookies!` (giữ hành vi: thử có/không cookie).
        let cookieAttempts: [String?] = (cookies?.isEmpty == false) ? [cookies, nil] : [nil]
        var lastError: Error?

        for cookieOpt in cookieAttempts {
            for ref in candidateReferers {
                var req = URLRequest(url: url)
                req.setValue(userAgent ?? URLNormalizer.defaultUserAgent, forHTTPHeaderField: "User-Agent")
                req.setValue("*/*", forHTTPHeaderField: "Accept")
                if let r = ref { req.setValue(r, forHTTPHeaderField: "Referer") }
                if let c = cookieOpt, !c.isEmpty { req.setValue(c, forHTTPHeaderField: "Cookie") }
                if let headers = customHeaders {
                    for (k, v) in headers {
                        req.setValue(v, forHTTPHeaderField: k)
                    }
                }
                if let br = byteRange {
                    let rangeHeader = "bytes=\(br.offset)-\(br.offset + br.length - 1)"
                    req.setValue(rangeHeader, forHTTPHeaderField: "Range")
                }

                do {
                    let (data, resp) = try await session.data(for: req)
                    guard let http = resp as? HTTPURLResponse else {
                        throw URLError(.badServerResponse)
                    }
                    // A-F6: có Range thì yêu cầu 206. Server trả 200 (bỏ qua
                    // Range) → cắt đúng cửa sổ [off, off+len), không ghi nguyên
                    // body (trước đây concat nhân đôi dữ liệu). Body ngắn hơn
                    // cửa sổ → throw retry (HLSDownloadError.isRetryable).
                    let rangedBody: Data
                    if let br = byteRange, http.statusCode == 200 {
                        let start = Int(br.offset)
                        let end = start + Int(br.length)
                        guard br.offset >= 0, br.length > 0, start >= 0,
                              end <= data.count, end > start else {
                            log.error("HLS byterange 200 body ngắn hơn cửa sổ [\(br.offset), \(br.offset + br.length)) (nhận \(data.count) byte) — thử lại")
                            throw HLSDownloadError.truncatedRangeBody(expected: br.offset + br.length, actual: data.count)
                        }
                        rangedBody = data.subdata(in: start..<end)
                    } else if (200...299).contains(http.statusCode) {
                        rangedBody = data
                    } else {
                        lastError = NSError(domain: "HLSDownloader", code: http.statusCode, userInfo: [
                            NSLocalizedDescriptionKey: "Segment HTTP \(http.statusCode)",
                            "retryAfter": http.value(forHTTPHeaderField: "Retry-After") ?? ""
                        ])
                        if http.statusCode != 403 {
                            break
                        }
                        continue
                    }
                    let finalData: Data
                    if let key = keyData, let ivData = iv {
                        finalData = try Self.decryptAES128(data: rangedBody, key: key, iv: ivData)
                    } else {
                        finalData = rangedBody
                    }
                    try finalData.write(to: destination)
                    return Int64(finalData.count)
                } catch {
                    // Lỗi decrypt sai key/IV hoặc body cụt đã có log/throw rõ ở
                    // trên — không thử referer khác (vô nghĩa), fail nhanh.
                    if error is HLSDownloadError { throw error }
                    lastError = error
                }
            }
        }
        throw lastError ?? URLError(.badServerResponse)
    }

    public func cancel() {
        isCancelled = true
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
