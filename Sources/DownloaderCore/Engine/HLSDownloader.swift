import Foundation
import CommonCrypto

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

    public init(
        uri: URL,
        duration: Double,
        index: Int,
        byteRange: HLSByteRange? = nil,
        keyInfo: HLSKeyInfo? = nil,
        initMap: HLSInitMap? = nil
    ) {
        self.uri = uri
        self.duration = duration
        self.index = index
        self.byteRange = byteRange
        self.keyInfo = keyInfo
        self.initMap = initMap
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

        for line in lines {
            if line.isEmpty { continue }

            if line.hasPrefix("#EXTINF:") {
                let durationStr = line.dropFirst("#EXTINF:".count).split(separator: ",")[0]
                currentDuration = Double(durationStr) ?? 0.0
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
                currentKeyInfo = parseKeyTag(keyStr, baseURL: baseURL)
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
                    initMap: currentInitMap
                ))
                segmentIndex += 1
                currentByteRange = nil
            }
        }

        return segments
    }

    public static func parseKeyTag(_ tag: String, baseURL: URL) -> HLSKeyInfo? {
        let attrs = parseAttributes(tag)
        guard let method = attrs["METHOD"], method != "NONE" else { return nil }
        guard let uriStr = attrs["URI"], !uriStr.isEmpty else { return nil }
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
    ) async throws {
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

        // If it's a master playlist pointing to child playlists, resolve the best quality one
        if segments.isEmpty && playlistString.contains("#EXT-X-STREAM-INF") {
            let lines = playlistString.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            var candidateStreams: [(bandwidth: Int, url: URL)] = []

            for i in 0..<lines.count {
                let line = lines[i]
                if line.hasPrefix("#EXT-X-MEDIA:") && line.contains("TYPE=AUDIO") && separateAudioURL == nil {
                    let attrs = Self.parseAttributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                    if let uriStr = attrs["URI"], !uriStr.isEmpty {
                        separateAudioURL = URL(string: uriStr, relativeTo: playlistURL)?.absoluteURL
                    }
                }
                if line.hasPrefix("#EXT-X-STREAM-INF:") {
                    var bw = 0
                    if let match = line.range(of: #"BANDWIDTH=(\d+)"#, options: .regularExpression) {
                        let sub = String(line[match]).replacingOccurrences(of: "BANDWIDTH=", with: "")
                        bw = Int(sub) ?? 0
                    }
                    if i + 1 < lines.count {
                        let nextLine = lines[i + 1]
                        if !nextLine.isEmpty && !nextLine.hasPrefix("#") {
                            let childURL = URL(string: nextLine, relativeTo: playlistURL)?.absoluteURL ?? playlistURL
                            candidateStreams.append((bandwidth: bw, url: childURL))
                        }
                    }
                }
            }

            candidateStreams.sort { $0.bandwidth > $1.bandwidth }

            for stream in candidateStreams {
                if let (childData, childWorkingRef) = try? await fetchPlaylistDataWithRefererFallback(
                    url: stream.url,
                    initialReferer: effectiveReferer,
                    userAgent: effectiveUA,
                    cookies: cookies,
                    customHeaders: customHeaders
                ),
                let childStr = String(data: childData, encoding: .utf8) {
                    segments = try Self.parsePlaylist(content: childStr, baseURL: stream.url)
                    if !segments.isEmpty {
                        effectiveReferer = childWorkingRef
                        break
                    }
                }
            }
        }

        guard !segments.isEmpty else {
            throw NSError(domain: "HLSDownloader", code: 1, userInfo: [NSLocalizedDescriptionKey: "No media segments found in playlist"])
        }

        // If fMP4 / CMAF init segment is specified, download it first
        let initFile = tempDirectory.appendingPathComponent("init_segment.mp4")
        if let initMap = segments.compactMap({ $0.initMap }).first {
            if !fileManager.fileExists(atPath: initFile.path) {
                _ = try await downloadSingleSegment(
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

        // Pre-scan already downloaded parts for resume capability
        for seg in segments {
            let dest = partFiles[seg.index]
            if fileManager.fileExists(atPath: dest.path),
               let attrs = try? fileManager.attributesOfItem(atPath: dest.path),
               let size = attrs[.size] as? Int64, size > 0 {
                downloadedCount += 1
                downloadedBytesTotal += size
            }
        }

        var nextSegmentIdx = 0
        func advanceToNextUnfinishedSegment() -> HLSSegmentInfo? {
            while nextSegmentIdx < segments.count {
                let seg = segments[nextSegmentIdx]
                nextSegmentIdx += 1
                let dest = partFiles[seg.index]
                if fileManager.fileExists(atPath: dest.path),
                   let attrs = try? fileManager.attributesOfItem(atPath: dest.path),
                   let size = attrs[.size] as? Int64, size > 0 {
                    continue
                }
                return seg
            }
            return nil
        }

        try await withThrowingTaskGroup(of: (slotIndex: Int, segmentIndex: Int, bytesCount: Int64).self) { group in
            for slot in 0..<concurrency {
                guard !isCancelled, let seg = advanceToNextUnfinishedSegment() else { break }
                let dest = partFiles[seg.index]
                let currentSlot = slot
                activeSegments[currentSlot].status = .downloading
                activeSegments[currentSlot].downloadedBytes = 0

                let keyData: Data?
                let ivData: Data?
                if let kInfo = seg.keyInfo {
                    keyData = try await self.getKeyData(
                        uri: kInfo.uri,
                        referer: effectiveReferer,
                        cookies: cookies,
                        userAgent: effectiveUA,
                        customHeaders: customHeaders
                    )
                    ivData = kInfo.iv ?? Self.makeDefaultIV(sequenceNumber: seg.index)
                } else {
                    keyData = nil
                    ivData = nil
                }

                group.addTask { [self] in
                    let bytesCount = try await self.downloadSingleSegment(
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

                if !isCancelled && !Task.isCancelled, let nextSeg = advanceToNextUnfinishedSegment() {
                    let dest = partFiles[nextSeg.index]
                    let currentSlot = slotIndex
                    activeSegments[currentSlot].status = .downloading
                    activeSegments[currentSlot].downloadedBytes = 0

                    let keyData: Data?
                    let ivData: Data?
                    if let kInfo = nextSeg.keyInfo {
                        keyData = try await self.getKeyData(
                            uri: kInfo.uri,
                            referer: effectiveReferer,
                            cookies: cookies,
                            userAgent: effectiveUA,
                            customHeaders: customHeaders
                        )
                        ivData = kInfo.iv ?? Self.makeDefaultIV(sequenceNumber: nextSeg.index)
                    } else {
                        keyData = nil
                        ivData = nil
                    }

                    group.addTask { [self] in
                        let bytesCount = try await self.downloadSingleSegment(
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

        let targetDir = destinationFile.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: targetDir.path) {
            try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
        }
        if fileManager.fileExists(atPath: destinationFile.path) {
            try fileManager.removeItem(at: destinationFile)
        }

        // If there was a separate audio track in master playlist, download audio
        var audioConcatFile: URL? = nil
        if let audioURL = separateAudioURL {
            let audioTempDir = tempDirectory.appendingPathComponent("audio_stream")
            let audioDest = tempDirectory.appendingPathComponent("audio_concat.ts")
            let audioDownloader = HLSDownloader(session: session)
            do {
                try await audioDownloader.download(
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
                }
            } catch {
                // Ignore audio failure and proceed with video
            }
        }

        var remuxed = false
        if destinationFile.pathExtension.lowercased() == "mp4", let ffmpeg = MediaURLResolver.findFfmpegBinary() {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffmpeg)
            if let audioFile = audioConcatFile, fileManager.fileExists(atPath: audioFile.path) {
                proc.arguments = ["-y", "-i", rawConcatFile.path, "-i", audioFile.path, "-c:v", "copy", "-c:a", "copy", "-movflags", "+faststart", destinationFile.path]
            } else {
                proc.arguments = ["-y", "-i", rawConcatFile.path, "-c", "copy", "-movflags", "+faststart", destinationFile.path]
            }
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            if (try? proc.run()) != nil {
                proc.waitUntilExit()
                if proc.terminationStatus == 0,
                   let size = (try? destinationFile.resourceValues(forKeys: [.fileSizeKey]).fileSize), size > 0 {
                    remuxed = true
                } else {
                    try? fileManager.removeItem(at: destinationFile)
                }
            }
        }

        if !remuxed {
            try fileManager.moveItem(at: rawConcatFile, to: destinationFile)
        }

        try? fileManager.removeItem(at: tempDirectory)
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
        let cookieAttempts: [String?] = (cookies != nil && !cookies!.isEmpty) ? [cookies, nil] : [nil]

        for cookieOpt in cookieAttempts {
            for candidate in candidateReferers {
                var req = URLRequest(url: url)
                req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                req.setValue("*/*", forHTTPHeaderField: "Accept")
                req.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
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

        let cookieAttempts: [String?] = (cookies != nil && !cookies!.isEmpty) ? [cookies, nil] : [nil]
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
                    if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                        let finalData: Data
                        if let key = keyData, let ivData = iv {
                            finalData = try Self.decryptAES128(data: data, key: key, iv: ivData)
                        } else {
                            finalData = data
                        }
                        try finalData.write(to: destination)
                        return Int64(finalData.count)
                    } else if let http = resp as? HTTPURLResponse {
                        lastError = NSError(domain: "HLSDownloader", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Segment HTTP \(http.statusCode)"])
                        if http.statusCode != 403 {
                            break
                        }
                    }
                } catch {
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
