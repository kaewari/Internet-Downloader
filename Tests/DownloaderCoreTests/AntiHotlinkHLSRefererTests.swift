import XCTest
@testable import DownloaderCore

final class AntiHotlinkHLSRefererTests: XCTestCase {

    final class MockAntiHotlinkProtocol: URLProtocol, @unchecked Sendable {
        static var lastPlaylistReferer: String?
        static var masterHitCount = 0
        static var rejectForeignCookie = false

        override class func canInit(with request: URLRequest) -> Bool {
            return request.url?.host == "cdn.example.com"
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            return request
        }

        override func startLoading() {
            guard let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }

            let referer = request.value(forHTTPHeaderField: "Referer")
            let cookie = request.value(forHTTPHeaderField: "Cookie")

            if Self.rejectForeignCookie && cookie != nil && !cookie!.isEmpty {
                let resp = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: [
                    "Content-Type": "text/html"
                ])!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("Forbidden: foreign cookie".utf8))
                client?.urlProtocolDidFinishLoading(self)
                return
            }

            if url.path.hasSuffix("index-f1-v1-a1.m3u8") {
                if referer == "https://cdn.example.com/stream/master.m3u8" {
                    let m3u8 = """
                    #EXTM3U
                    #EXT-X-TARGETDURATION:10
                    #EXTINF:10.0,
                    seg1.ts
                    """
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                        "Content-Type": "application/vnd.apple.mpegurl"
                    ])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Data(m3u8.utf8))
                    client?.urlProtocolDidFinishLoading(self)
                    return
                } else {
                    let resp = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Data("Forbidden".utf8))
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }
            }

            if url.path.hasSuffix("master.m3u8") {
                Self.masterHitCount += 1
                Self.lastPlaylistReferer = referer

                // Reject cross-origin referer with HTTP 403 Forbidden
                if referer == "https://blocked-origin.com/page" {
                    let resp = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: [
                        "Content-Type": "text/html"
                    ])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Data("Forbidden".utf8))
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }

                // Accept same-origin referer
                if referer == "https://cdn.example.com/" || referer == "https://cdn.example.com/master.m3u8" {
                    let m3u8 = """
                    #EXTM3U
                    #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1920x1080
                    child.m3u8
                    """
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                        "Content-Type": "application/vnd.apple.mpegurl"
                    ])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Data(m3u8.utf8))
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }

                // Any other referer rejected
                let resp = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("Forbidden".utf8))
                client?.urlProtocolDidFinishLoading(self)
                return
            }

            if url.path.hasSuffix("child.m3u8") {
                if referer == "https://cdn.example.com/" || referer == "https://cdn.example.com/master.m3u8" {
                    let m3u8 = """
                    #EXTM3U
                    #EXT-X-TARGETDURATION:10
                    #EXTINF:10.0,
                    seg1.ts
                    """
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                        "Content-Type": "application/vnd.apple.mpegurl"
                    ])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Data(m3u8.utf8))
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }

                let resp = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("Forbidden".utf8))
                client?.urlProtocolDidFinishLoading(self)
                return
            }

            if url.path.hasSuffix("seg1.ts") {
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                    "Content-Type": "video/mp2t"
                ])!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                // 188-byte valid TS packet starting with sync byte 0x47
                var packet = [UInt8](repeating: 0xFF, count: 188)
                packet[0] = 0x47
                client?.urlProtocol(self, didLoad: Data(packet))
                client?.urlProtocolDidFinishLoading(self)
                return
            }

            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
        }

        override func stopLoading() {}
    }

    func testHLSDownloaderRecoversFrom403CrossOriginRefererWithSameOriginFallback() async throws {
        MockAntiHotlinkProtocol.lastPlaylistReferer = nil
        MockAntiHotlinkProtocol.masterHitCount = 0

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockAntiHotlinkProtocol.self]
        let mockSession = URLSession(configuration: config)
        let downloader = HLSDownloader(session: mockSession)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("hls_test_\(UUID().uuidString)")
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("output_\(UUID().uuidString).ts")
        defer {
            if FileManager.default.fileExists(atPath: tempDir.path) {
                try? FileManager.default.removeItem(at: tempDir)
            }
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
        }

        do {
            try await downloader.download(
                playlistURL: URL(string: "https://cdn.example.com/stream/master.m3u8")!,
                destinationFile: dest,
                tempDirectory: tempDir,
                cookies: nil,
                referrer: "https://blocked-origin.com/page",
                userAgent: "TestAgent",
                onProgress: { _, _, _, _, _, _ in }
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
            XCTAssertGreaterThan(MockAntiHotlinkProtocol.masterHitCount, 1, "Should have retried master playlist when first attempt failed with 403")
            XCTAssertEqual(MockAntiHotlinkProtocol.lastPlaylistReferer, "https://cdn.example.com/")
        } catch {
            print(">>> Actual caught error in test: \(error)")
            throw error
        }
    }

    func testHLSDownloaderRecoversFrom403ByStrippingForeignCookies() async throws {
        MockAntiHotlinkProtocol.lastPlaylistReferer = nil
        MockAntiHotlinkProtocol.masterHitCount = 0
        MockAntiHotlinkProtocol.rejectForeignCookie = true
        defer { MockAntiHotlinkProtocol.rejectForeignCookie = false }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockAntiHotlinkProtocol.self]
        let mockSession = URLSession(configuration: config)
        let downloader = HLSDownloader(session: mockSession)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("hls_cookie_test_\(UUID().uuidString)")
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("output_cookie_\(UUID().uuidString).ts")
        defer {
            if FileManager.default.fileExists(atPath: tempDir.path) {
                try? FileManager.default.removeItem(at: tempDir)
            }
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
        }

        try await downloader.download(
            playlistURL: URL(string: "https://cdn.example.com/stream/master.m3u8")!,
            destinationFile: dest,
            tempDirectory: tempDir,
            cookies: "tsn=7", // foreign cookie that causes 403
            referrer: "https://cdn.example.com/",
            userAgent: "TestAgent",
            onProgress: { _, _, _, _, _, _ in }
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path), "Should successfully download after retrying without foreign cookies")
    }

    func testHLSDownloaderRecoversFromChildPlaylistWithMasterReferer() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockAntiHotlinkProtocol.self]
        let mockSession = URLSession(configuration: config)
        let downloader = HLSDownloader(session: mockSession)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("hls_child_test_\(UUID().uuidString)")
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("output_child_\(UUID().uuidString).ts")
        defer {
            if FileManager.default.fileExists(atPath: tempDir.path) {
                try? FileManager.default.removeItem(at: tempDir)
            }
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
        }

        try await downloader.download(
            playlistURL: URL(string: "https://cdn.example.com/stream/index-f1-v1-a1.m3u8")!,
            destinationFile: dest,
            tempDirectory: tempDir,
            cookies: nil,
            referrer: "https://unrelated-domain.com/video",
            userAgent: "TestAgent",
            onProgress: { _, _, _, _, _, _ in }
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path), "Should successfully download child playlist using candidate master.m3u8 referer")
    }
}
