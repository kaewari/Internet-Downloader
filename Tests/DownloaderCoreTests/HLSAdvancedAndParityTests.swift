import XCTest
import CommonCrypto
@testable import DownloaderCore

final class HLSAdvancedAndParityTests: XCTestCase {

    // Resolve ffmpeg/ffprobe: ENV (FFMPEG/FFPROBE) → /opt/homebrew → /usr/local → which. Nil khi thiếu.
    private func find_ffmpeg() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let override = env["FFMPEG"], FileManager.default.isExecutableFile(atPath: override) { return override }
        for candidate in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["ffmpeg"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        let found = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return found.isEmpty ? nil : found
    }

    private func find_ffprobe() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let override = env["FFPROBE"], FileManager.default.isExecutableFile(atPath: override) { return override }
        for candidate in ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["ffprobe"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        let found = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return found.isEmpty ? nil : found
    }

    // 1. Test #EXT-X-BYTERANGE parsing (explicit and implicit offset)
    func testHLSByteRangeParsingAndOffsets() throws {
        let m3u8 = """
        #EXTM3U
        #EXT-X-TARGETDURATION:10
        #EXT-X-VERSION:4
        #EXTINF:9.9,
        #EXT-X-BYTERANGE:326744@0
        main.ts
        #EXTINF:9.9,
        #EXT-X-BYTERANGE:326368@326744
        main.ts
        #EXTINF:10.0,
        #EXT-X-BYTERANGE:327120
        main.ts
        """
        let baseURL = URL(string: "https://example.com/stream/playlist.m3u8")!
        let segments = try HLSDownloader.parsePlaylist(content: m3u8, baseURL: baseURL)

        XCTAssertEqual(segments.count, 3)

        // Segment 0: 326744@0
        XCTAssertEqual(segments[0].byteRange?.length, 326744)
        XCTAssertEqual(segments[0].byteRange?.offset, 0)
        XCTAssertEqual(segments[0].uri.absoluteString, "https://example.com/stream/main.ts")

        // Segment 1: 326368@326744
        XCTAssertEqual(segments[1].byteRange?.length, 326368)
        XCTAssertEqual(segments[1].byteRange?.offset, 326744)

        // Segment 2: implicit offset following segment 1 (326744 + 326368 = 653112)
        XCTAssertEqual(segments[2].byteRange?.length, 327120)
        XCTAssertEqual(segments[2].byteRange?.offset, 653112)
    }

    // 2. Test #EXT-X-KEY tag parsing with URI and IV
    func testHLSAES128KeyTagParsing() throws {
        let m3u8 = """
        #EXTM3U
        #EXT-X-TARGETDURATION:10
        #EXT-X-KEY:METHOD=AES-128,URI="https://priv.example.com/key.bin",IV=0x000102030405060708090a0b0c0d0e0f
        #EXTINF:10.0,
        seg0.ts
        #EXT-X-KEY:METHOD=NONE
        #EXTINF:10.0,
        seg1.ts
        """
        let baseURL = URL(string: "https://example.com/stream/playlist.m3u8")!
        let segments = try HLSDownloader.parsePlaylist(content: m3u8, baseURL: baseURL)

        XCTAssertEqual(segments.count, 2)

        // Segment 0 has AES-128 key info
        let keyInfo = segments[0].keyInfo
        XCTAssertNotNil(keyInfo)
        XCTAssertEqual(keyInfo?.method, "AES-128")
        XCTAssertEqual(keyInfo?.uri.absoluteString, "https://priv.example.com/key.bin")
        XCTAssertNotNil(keyInfo?.iv)
        XCTAssertEqual(keyInfo?.iv?.count, 16)
        XCTAssertEqual(keyInfo?.iv?[0], 0x00)
        XCTAssertEqual(keyInfo?.iv?[1], 0x01)
        XCTAssertEqual(keyInfo?.iv?[15], 0x0f)

        // Segment 1 has METHOD=NONE
        XCTAssertNil(segments[1].keyInfo)
    }

    // 3. Test AES-128 decryption bit-exact match with CommonCrypto
    func testHLSAES128DecryptionBitExact() throws {
        // 16-byte key
        let key = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
                        0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F])
        // 16-byte IV
        let iv = Data([0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
                       0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F])

        let plaintext = Data("HelloWorldTestMedia1234567890ABCDEFInternetDownloaderParityTest".utf8)

        // Encrypt with CommonCrypto AES-128-CBC PKCS7
        var ciphertext = Data(count: plaintext.count + kCCBlockSizeAES128)
        var numBytesEncrypted: size_t = 0
        let encryptStatus = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                plaintext.withUnsafeBytes { plainBytes in
                    ciphertext.withUnsafeMutableBytes { outBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, kCCKeySizeAES128,
                            ivBytes.baseAddress,
                            plainBytes.baseAddress, plaintext.count,
                            outBytes.baseAddress, outBytes.count,
                            &numBytesEncrypted
                        )
                    }
                }
            }
        }
        XCTAssertEqual(encryptStatus, Int32(kCCSuccess))
        ciphertext.removeSubrange(numBytesEncrypted..<ciphertext.count)

        // Decrypt using HLSDownloader.decryptAES128
        let decrypted = try HLSDownloader.decryptAES128(data: ciphertext, key: key, iv: iv)
        XCTAssertEqual(decrypted, plaintext)

        // Invalid key length error handling
        let invalidKey = Data([0x01, 0x02])
        XCTAssertThrowsError(try HLSDownloader.decryptAES128(data: ciphertext, key: invalidKey, iv: iv))

        // Invalid IV length error handling
        let invalidIV = Data([0x01, 0x02, 0x03])
        XCTAssertThrowsError(try HLSDownloader.decryptAES128(data: ciphertext, key: key, iv: invalidIV))
    }

    // 4. Test RFC 8216 Default IV generation for implicit sequence numbers
    func testHLSDefaultIVGeneration() {
        let iv0 = HLSDownloader.makeDefaultIV(sequenceNumber: 0)
        XCTAssertEqual(iv0.count, 16)
        XCTAssertEqual(iv0, Data(repeating: 0, count: 16))

        let iv1 = HLSDownloader.makeDefaultIV(sequenceNumber: 1)
        XCTAssertEqual(iv1.count, 16)
        XCTAssertEqual(iv1[15], 1)
        XCTAssertEqual(iv1[0..<15], Data(repeating: 0, count: 15))

        let iv258 = HLSDownloader.makeDefaultIV(sequenceNumber: 258) // 0x0102
        XCTAssertEqual(iv258.count, 16)
        XCTAssertEqual(iv258[14], 1)
        XCTAssertEqual(iv258[15], 2)
    }

    // 5. Test #EXT-X-MAP (Fragmented MP4 init segment) parsing
    func testHLSInitMapFragmentedMP4Parsing() throws {
        let m3u8 = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MAP:URI="init.mp4",BYTERANGE="1024@0"
        #EXTINF:6.0,
        segment1.m4s
        """
        let baseURL = URL(string: "https://example.com/hls/stream.m3u8")!
        let segments = try HLSDownloader.parsePlaylist(content: m3u8, baseURL: baseURL)

        XCTAssertEqual(segments.count, 1)
        let initMap = segments[0].initMap
        XCTAssertNotNil(initMap)
        XCTAssertEqual(initMap?.uri.absoluteString, "https://example.com/hls/init.mp4")
        XCTAssertEqual(initMap?.byteRange?.length, 1024)
        XCTAssertEqual(initMap?.byteRange?.offset, 0)
    }

    // 6. Test MediaURLResolver strictly rejects images (og:image / twitter:image)
    func testMediaURLResolverRejectsImageFallbacks() async {
        // Mock session that returns HTML containing only og:image and twitter:image
        final class ImageOnlyHTMLProtocol: URLProtocol, @unchecked Sendable {
            override class func canInit(with request: URLRequest) -> Bool {
                return request.url?.host == "imageonly.example.com"
            }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                let html = """
                <!DOCTYPE html>
                <html>
                <head>
                    <meta property="og:title" content="No Video Here" />
                    <meta property="og:image" content="https://imageonly.example.com/poster.jpg" />
                    <meta name="twitter:image" content="https://imageonly.example.com/preview.png" />
                </head>
                <body><p>Just text</p></body>
                </html>
                """
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(html.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ImageOnlyHTMLProtocol.self]
        // Resolve should return nil because image meta tags were removed from video ogPatterns
        let testURL = URL(string: "https://imageonly.example.com/article/123")!
        let result = await MediaURLResolver.resolveWithHTMLFallback(url: testURL, customHeaders: nil, userAgent: nil)
        XCTAssertNil(result, "resolveWithHTMLFallback must not return og:image or twitter:image as a video media stream")
    }

    // 7. Test custom request headers propagation to DownloadTask & SQLiteStore
    func testHeaderForwardingIntoTaskAndManager() throws {
        let tempDB = FileManager.default.temporaryDirectory.appendingPathComponent("test_headers_\(UUID().uuidString).sqlite3").path
        defer { try? FileManager.default.removeItem(atPath: tempDB) }
        let manager = DownloadManager(dbPath: tempDB)

        let testURL = URL(string: "https://video.fna.fbcdn.net/v/test.mp4")!
        let customHeaders = [
            "Origin": "https://www.facebook.com",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Site": "cross-site",
            "Authorization": "Bearer sample_token_123"
        ]

        let task = try manager.createNewTask(
            url: testURL,
            filename: "fb_video.mp4",
            destinationFolder: FileManager.default.temporaryDirectory,
            referrer: "https://www.facebook.com/watch/?v=123",
            userAgent: "Mozilla/5.0 Custom Test",
            cookies: "c_user=10001; xs=valid_session",
            headers: customHeaders
        )

        // Verify task model retains headers
        XCTAssertEqual(task.headers?["Origin"], "https://www.facebook.com")
        XCTAssertEqual(task.headers?["Sec-Fetch-Mode"], "cors")
        XCTAssertEqual(task.headers?["Authorization"], "Bearer sample_token_123")

        // Verify SQLiteStore persistence and recovery
        let store = try SQLiteStore(path: tempDB)
        let loaded = try store.getTask(id: task.id)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.headers?["Origin"], "https://www.facebook.com")
        XCTAssertEqual(loaded?.headers?["Authorization"], "Bearer sample_token_123")
    }

    // 8. Integration test: End-to-end HLS download with AES-128 decryption
    func testHLSDownloaderEndToEndAES128Decryption() async throws {
        let key = Data([0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
                        0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F])
        let iv = Data([0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27,
                       0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F])
        let plaintext = Data("EncryptedStreamClearContentForTestingBitExactAssembly123456789".utf8)

        // Encrypt plaintext with AES-128-CBC PKCS7
        var ciphertext = Data(count: plaintext.count + kCCBlockSizeAES128)
        var numBytesEncrypted: size_t = 0
        let encryptStatus = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                plaintext.withUnsafeBytes { plainBytes in
                    ciphertext.withUnsafeMutableBytes { outBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, kCCKeySizeAES128,
                            ivBytes.baseAddress,
                            plainBytes.baseAddress, plaintext.count,
                            outBytes.baseAddress, outBytes.count,
                            &numBytesEncrypted
                        )
                    }
                }
            }
        }
        XCTAssertEqual(encryptStatus, Int32(kCCSuccess))
        ciphertext.removeSubrange(numBytesEncrypted..<ciphertext.count)

        final class MockAES128Protocol: URLProtocol, @unchecked Sendable {
            static var mockKey: Data!
            static var mockCiphertext: Data!
            static var ivHex: String!

            override class func canInit(with request: URLRequest) -> Bool {
                return request.url?.host == "mockaes.example.com"
            }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

            override func startLoading() {
                guard let url = request.url else { return }
                if url.path.hasSuffix("playlist.m3u8") {
                    let m3u8 = """
                    #EXTM3U
                    #EXT-X-TARGETDURATION:5
                    #EXT-X-KEY:METHOD=AES-128,URI="https://mockaes.example.com/key.bin",IV=0x\(Self.ivHex!)
                    #EXTINF:5.0,
                    seg0.ts
                    """
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/vnd.apple.mpegurl"])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Data(m3u8.utf8))
                    client?.urlProtocolDidFinishLoading(self)
                } else if url.path.hasSuffix("key.bin") {
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/octet-stream"])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Self.mockKey)
                    client?.urlProtocolDidFinishLoading(self)
                } else if url.path.hasSuffix("seg0.ts") {
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "video/mp2t"])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Self.mockCiphertext)
                    client?.urlProtocolDidFinishLoading(self)
                }
            }
            override func stopLoading() {}
        }

        MockAES128Protocol.mockKey = key
        MockAES128Protocol.mockCiphertext = ciphertext
        MockAES128Protocol.ivHex = iv.map { String(format: "%02x", $0) }.joined()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockAES128Protocol.self]
        let mockSession = URLSession(configuration: config)

        let downloader = HLSDownloader(session: mockSession)
        let baseDir = FileManager.default.temporaryDirectory.appendingPathComponent("hls_test_\(UUID().uuidString)")
        let tempDir = baseDir.appendingPathComponent("temp")
        let destFile = baseDir.appendingPathComponent("output.ts")
        defer { try? FileManager.default.removeItem(at: baseDir) }

        try await downloader.download(
            playlistURL: URL(string: "https://mockaes.example.com/playlist.m3u8")!,
            destinationFile: destFile,
            tempDirectory: tempDir,
            onProgress: { _, _, _, _, _, _ in }
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: destFile.path))
        let downloadedData = try Data(contentsOf: destFile)
        XCTAssertEqual(downloadedData, plaintext, "The downloaded and decrypted file must match original plaintext exactly!")
    }

    // 9. Integration test: End-to-end HLS download with byte-range requests
    func testHLSDownloaderEndToEndByteRangeDownload() async throws {
        let masterResource = Data((0..<2000).map { UInt8($0 % 256) })

        final class MockByteRangeProtocol: URLProtocol, @unchecked Sendable {
            static var mockMasterResource: Data!
            static var receivedRangeHeader: String?

            override class func canInit(with request: URLRequest) -> Bool {
                return request.url?.host == "mockrange.example.com"
            }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

            override func startLoading() {
                guard let url = request.url else { return }
                if url.path.hasSuffix("playlist.m3u8") {
                    let m3u8 = """
                    #EXTM3U
                    #EXT-X-TARGETDURATION:5
                    #EXTINF:5.0,
                    #EXT-X-BYTERANGE:300@150
                    main.ts
                    """
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/vnd.apple.mpegurl"])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Data(m3u8.utf8))
                    client?.urlProtocolDidFinishLoading(self)
                } else if url.path.hasSuffix("main.ts") {
                    Self.receivedRangeHeader = request.value(forHTTPHeaderField: "Range")
                    let slice = Self.mockMasterResource.subdata(in: 150..<450)
                    let resp = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: [
                        "Content-Type": "video/mp2t",
                        "Content-Range": "bytes 150-449/2000"
                    ])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: slice)
                    client?.urlProtocolDidFinishLoading(self)
                }
            }
            override func stopLoading() {}
        }

        MockByteRangeProtocol.mockMasterResource = masterResource
        MockByteRangeProtocol.receivedRangeHeader = nil

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockByteRangeProtocol.self]
        let mockSession = URLSession(configuration: config)

        let downloader = HLSDownloader(session: mockSession)
        let baseDir = FileManager.default.temporaryDirectory.appendingPathComponent("hls_range_test_\(UUID().uuidString)")
        let tempDir = baseDir.appendingPathComponent("temp")
        let destFile = baseDir.appendingPathComponent("output.ts")
        defer { try? FileManager.default.removeItem(at: baseDir) }

        try await downloader.download(
            playlistURL: URL(string: "https://mockrange.example.com/playlist.m3u8")!,
            destinationFile: destFile,
            tempDirectory: tempDir,
            onProgress: { _, _, _, _, _, _ in }
        )

        XCTAssertEqual(MockByteRangeProtocol.receivedRangeHeader, "bytes=150-449", "HLSDownloader must send correct HTTP Range header for #EXT-X-BYTERANGE")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destFile.path))
        let downloadedData = try Data(contentsOf: destFile)
        let expectedSlice = masterResource.subdata(in: 150..<450)
        XCTAssertEqual(downloadedData, expectedSlice, "Downloaded slice must match the exact byte-range from master resource!")
    }

    // 10. Integration test: End-to-end HLS download with ffmpeg remuxing and ffprobe media validation
    func testHLSDownloaderRemuxAndFFprobeVerification() async throws {
        guard let ffmpeg = MediaURLResolver.findFfmpegBinary() else {
            // If ffmpeg is not installed, skip this integration check
            return
        }

        // Generate a 1-second valid test TS segment with h264 video and aac audio
        let genProc = Process()
        genProc.executableURL = URL(fileURLWithPath: ffmpeg)
        let sampleTSPath = FileManager.default.temporaryDirectory.appendingPathComponent("gen_\(UUID().uuidString).ts")
        defer { try? FileManager.default.removeItem(at: sampleTSPath) }

        genProc.arguments = [
            "-f", "lavfi", "-i", "testsrc=duration=1:size=320x240:rate=30",
            "-f", "lavfi", "-i", "sine=duration=1",
            "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac",
            "-f", "mpegts", "-y", sampleTSPath.path
        ]
        try genProc.run()
        genProc.waitUntilExit()
        XCTAssertEqual(genProc.terminationStatus, 0)
        let sampleTSData = try Data(contentsOf: sampleTSPath)
        XCTAssertGreaterThan(sampleTSData.count, 1024)

        final class MockPlayableHLSProtocol: URLProtocol, @unchecked Sendable {
            static var tsData: Data!

            override class func canInit(with request: URLRequest) -> Bool {
                return request.url?.host == "mockplayable.example.com"
            }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

            override func startLoading() {
                guard let url = request.url else { return }
                if url.path.hasSuffix("playlist.m3u8") {
                    let m3u8 = """
                    #EXTM3U
                    #EXT-X-TARGETDURATION:2
                    #EXTINF:1.0,
                    seg0.ts
                    #EXTINF:1.0,
                    seg1.ts
                    """
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/vnd.apple.mpegurl"])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Data(m3u8.utf8))
                    client?.urlProtocolDidFinishLoading(self)
                } else if url.path.hasSuffix(".ts") {
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "video/mp2t"])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Self.tsData)
                    client?.urlProtocolDidFinishLoading(self)
                }
            }
            override func stopLoading() {}
        }

        MockPlayableHLSProtocol.tsData = sampleTSData

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockPlayableHLSProtocol.self]
        let mockSession = URLSession(configuration: config)

        let downloader = HLSDownloader(session: mockSession)
        let baseDir = FileManager.default.temporaryDirectory.appendingPathComponent("hls_ffprobe_test_\(UUID().uuidString)")
        let tempDir = baseDir.appendingPathComponent("temp")
        let destMP4 = baseDir.appendingPathComponent("playable_output.mp4")
        defer { try? FileManager.default.removeItem(at: baseDir) }

        try await downloader.download(
            playlistURL: URL(string: "https://mockplayable.example.com/playlist.m3u8")!,
            destinationFile: destMP4,
            tempDirectory: tempDir,
            onProgress: { _, _, _, _, _, _ in }
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: destMP4.path))
        let destSize = (try? destMP4.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        XCTAssertGreaterThan(destSize, 1024, "Destination MP4 must be populated with remuxed data")

        // Validate using ffprobe to confirm that the file is playable and contains video/audio streams
        guard let ffprobe = find_ffprobe() else {
            throw XCTSkip("ffprobe không khả dụng (FFPROBE → /opt/homebrew → /usr/local → which)")
        }
        let probeProc = Process()
        probeProc.executableURL = URL(fileURLWithPath: ffprobe)
        probeProc.arguments = [
            "-v", "error",
            "-show_entries", "format=format_name,duration:stream=codec_type,codec_name",
            "-of", "json",
            destMP4.path
        ]
        let outPipe = Pipe()
        probeProc.standardOutput = outPipe
        try probeProc.run()
        probeProc.waitUntilExit()

        XCTAssertEqual(probeProc.terminationStatus, 0, "ffprobe must exit with 0 on valid downloaded MP4 file")
        let probeData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let probeJson = (try? JSONSerialization.jsonObject(with: probeData)) as? [String: Any]
        let streams = probeJson?["streams"] as? [[String: Any]] ?? []
        XCTAssertGreaterThanOrEqual(streams.count, 2, "Downloaded MP4 must contain at least 2 streams (video + audio)")
        let videoStream = streams.first(where: { ($0["codec_type"] as? String) == "video" })
        let audioStream = streams.first(where: { ($0["codec_type"] as? String) == "audio" })
        XCTAssertNotNil(videoStream, "Video stream must be present in downloaded file")
        XCTAssertNotNil(audioStream, "Audio stream must be present in downloaded file")
        XCTAssertEqual(videoStream?["codec_name"] as? String, "h264")
        XCTAssertEqual(audioStream?["codec_name"] as? String, "aac")
    }

    // 11. Live integration test: Download a real Facebook CDN image via DownloadManager with Referer and custom headers
    func testDownloadRealFacebookImageAndVerify() async throws {
        let tempDB = FileManager.default.temporaryDirectory.appendingPathComponent("test_fb_\(UUID().uuidString).sqlite3").path
        defer { try? FileManager.default.removeItem(atPath: tempDB) }
        let manager = DownloadManager(dbPath: tempDB)

        let fbURLString = "https://scontent.fhnd4-1.fna.fbcdn.net/v/t15.5256-10/759010571_1816855926027707_8177865488497857662_n.jpg?_nc_cat=108&_nc_map=urlgen_bucketless&ccb=1-7&_nc_sid=b07905&_nc_ohc=Z43ly1eD3LQQ7kNvwFSbRnE&_nc_oc=AdqG0WNeJTM7wP2OHgT886htU29w_k8fJqWz8n5jHRx8huYPjP1nIptCR8bCVJ6WuVpCNZN9HxdbprFszavwAHbE&_nc_zt=23&_nc_ht=scontent.fhnd4-1.fna&_nc_gid=sk_5MAP7QPeGgbTZHQO7Cg&_nc_ss=7020f&oh=00_AQNWOfJ7NPx0KD4IZ5HH0tUAvlaw6O3_xf4cikflBW8YmQ&oe=6AD2BD6D"
        guard let fbURL = URL(string: fbURLString) else { return }

        // Preflight: this photo URL carries a time-limited CDN signature (`oe=`) and expires,
        // which would make the test flaky. Skip when it is no longer valid instead of failing.
        var preflight = URLRequest(url: fbURL)
        preflight.timeoutInterval = 10
        preflight.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        preflight.setValue("https://www.facebook.com/", forHTTPHeaderField: "Referer")
        preflight.setValue("bytes=0-15", forHTTPHeaderField: "Range")
        let (_, preflightResponse) = try await URLSession.shared.data(for: preflight)
        let preflightStatus = (preflightResponse as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(preflightStatus) else {
            throw XCTSkip("Facebook CDN signature URL has expired (HTTP \(preflightStatus)); refresh the URL to re-enable this test.")
        }

        let destFolder = FileManager.default.temporaryDirectory.appendingPathComponent("fb_download_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destFolder) }

        let task = try manager.createNewTask(
            url: fbURL,
            filename: "facebook_image.jpg",
            destinationFolder: destFolder,
            referrer: "https://www.facebook.com/",
            headers: [
                "Origin": "https://www.facebook.com",
                "Referer": "https://www.facebook.com/",
                "Sec-Fetch-Site": "cross-site",
                "Sec-Fetch-Mode": "no-cors"
            ]
        )

        let completedExp = expectation(description: "Facebook image download completed")
        manager.onDownloadCompleted = { completedTask in
            if completedTask.id == task.id {
                completedExp.fulfill()
            }
        }

        manager.startDownload(taskId: task.id)
        await fulfillment(of: [completedExp], timeout: 15.0)

        let targetFile = destFolder.appendingPathComponent("facebook_image.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetFile.path))
        let fileSize = (try? targetFile.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        XCTAssertGreaterThan(fileSize, 10000, "Downloaded Facebook image must be non-empty and greater than 10KB")

        // Validate magic bytes
        let fileData = try Data(contentsOf: targetFile)
        XCTAssertTrue(fileData.starts(with: [0xff, 0xd8, 0xff]), "File must be valid JPEG image starting with FFD8FF")
    }
}

