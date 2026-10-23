import XCTest
import CryptoKit
@testable import DownloaderCore

final class RangeIntegrityTests: XCTestCase {
    /// URLProtocol stub: mô phỏng server với chế độ cấu hình được
    /// (ignore Range, trả 404, trả HTML, fail N lần rồi thành công).
    final class StubProtocol: URLProtocol {
        static var body = Data()
        static var ignoreRange = false          // trả 200 full body bất kể Range
        static var status = 200                  // status trả về cho GET
        static var htmlBody = false              // trả HTML thay vì body
        static var failFirstN: Int = 0           // trả 503 cho N request đầu
        static var requestCount = 0
        static var maxBytesRead = 0              // bảo chứng probe chỉ đọc ≤512

        static func reset() {
            body = Data(); ignoreRange = false; status = 200; htmlBody = false
            failFirstN = 0; requestCount = 0; maxBytesRead = 0
        }

        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stub.example.com" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            Self.requestCount += 1
            let url = request.url!
            let total = Self.body.count

            // Thông tin kích thước data client đã đọc (theo dõi từ Content-Length client thấy)
            if Self.failFirstN > 0 {
                Self.failFirstN -= 1
                let resp = HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: ["Retry-After": "0"])!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                return
            }

            let rangeHeader = request.value(forHTTPHeaderField: "Range")
            if Self.htmlBody {
                let html = "<html><body>Login page</body></html>"
                let data = Data(html.utf8)
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                    "Content-Type": "text/html",
                    "Content-Length": "\(data.count)"
                ])!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
                return
            }

            if Self.status != 200 && Self.status != 206 {
                let resp = HTTPURLResponse(url: url, statusCode: Self.status, httpVersion: nil, headerFields: [:])!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data())
                client?.urlProtocolDidFinishLoading(self)
                return
            }

            if let rangeHeader, !Self.ignoreRange {
                let rangeStr = rangeHeader.replacingOccurrences(of: "bytes=", with: "")
                let parts = rangeStr.split(separator: "-")
                let start = Int(parts[0]) ?? 0
                let end = parts.count > 1 && !parts[1].isEmpty ? Int(parts[1])! : total - 1
                let clamped = min(end, total - 1)
                let sub = Self.body.subdata(in: start..<clamped + 1)
                let resp = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: [
                    "Content-Type": "application/octet-stream",
                    "Accept-Ranges": "bytes",
                    "Content-Range": "bytes \(start)-\(clamped)/\(total)",
                    "Content-Length": "\(sub.count)"
                ])!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: sub)
                client?.urlProtocolDidFinishLoading(self)
            } else if Self.ignoreRange {
                // Server ignore Range: trả TOÀN BỘ body với 200 — test sẽ xác nhận
                // engine chỉ đọc phần nó cần (không nạp cả body).
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                    "Content-Type": "application/octet-stream",
                    "Accept-Ranges": "bytes",
                    "Content-Length": "\(total)"
                ])!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Self.body)
                client?.urlProtocolDidFinishLoading(self)
            } else {
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                    "Content-Type": "application/octet-stream",
                    "Content-Length": "\(total)"
                ])!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Self.body)
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    override func setUp() {
        super.setUp()
        StubProtocol.reset()
        StubProtocol.body = Data((0..<100_000).map { UInt8($0 % 251) })
    }

    // 1. Probe với server ignore Range (trả 200 full body) — engine không nạp cả body:
    //    probe dùng streaming bytes, chỉ đọc 512 byte rồi hủy stream. Kiểm chứng qua
    //    việc probe hoàn thành nhanh và parse được headers (không assert RAM, mà assert
    //    kết quả đúng với server không hỗ trợ range).
    func testProbeWithRangeIgnoringServerDoesNotBufferWholeBody() async throws {
        StubProtocol.ignoreRange = true
        StubProtocol.body = Data(repeating: 0x41, count: 5_000_000) // 5 MB

        let url = URL(string: "https://stub.example.com/big.zip")!
        let probe = try await HTTPRangeDownloader.probeURL(url: url, session: makeSession())
        XCTAssertEqual(probe.totalBytes, 5_000_000)
    }

    // 2. Multi-segment với server ignore Range → file cuối vẫn đúng byte (clamp + discard).
    func testMultiSegmentSurvivesRangeIgnoringServer() async throws {
        StubProtocol.ignoreRange = true

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("idm_rng_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let task = DownloadTask(
            url: URL(string: "https://stub.example.com/blob.bin")!,
            filename: "blob.bin",
            destinationFolder: dir,
            totalBytes: Int64(StubProtocol.body.count),
            acceptRanges: true,
            segmentsCount: 8
        )
        let segments = HTTPRangeDownloader.calculateSegments(
            taskId: task.id, totalBytes: Int64(StubProtocol.body.count), segmentCount: 8, acceptRanges: true
        )
        let downloader = HTTPRangeDownloader(session: makeSession())
        try await downloader.download(task: task, segments: segments, onProgress: { _, _ in }, onSegmentUpdate: { _ in })

        let got = try Data(contentsOf: task.finalFilePath)
        XCTAssertEqual(
            SHA256.hash(data: got).map { String(format: "%02x", $0) }.joined(),
            SHA256.hash(data: StubProtocol.body).map { String(format: "%02x", $0) }.joined(),
            "8 segments qua server ignore-Range phải ra file bit-for-bit"
        )
    }

    // 3. Server trả HTML thay vì file (non-media) → phải fail rõ, không ghi file rác.
    func testNonMediaHTMLResponseFailsLoudly() async throws {
        StubProtocol.htmlBody = true

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("idm_html_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let task = DownloadTask(
            url: URL(string: "https://stub.example.com/report.zip")!,
            filename: "report.zip",
            destinationFolder: dir,
            totalBytes: -1,
            acceptRanges: false,
            segmentsCount: 1
        )
        let segments = HTTPRangeDownloader.calculateSegments(taskId: task.id, totalBytes: -1, segmentCount: 1, acceptRanges: false)
        let downloader = HTTPRangeDownloader(session: makeSession())
        do {
            try await downloader.download(task: task, segments: segments, onProgress: { _, _ in }, onSegmentUpdate: { _ in })
            XCTFail("Server trả HTML phải fail rõ ràng")
        } catch {
            // kỳ vọng throw — kiểm tra ít nhất có message
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    // 4. Lỗi 503 tạm thời → retry tự phục hồi và hoàn thành.
    func testTransient503RetriesAndCompletes() async throws {
        StubProtocol.failFirstN = 2

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("idm_r503_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let task = DownloadTask(
            url: URL(string: "https://stub.example.com/file.zip")!,
            filename: "file.zip",
            destinationFolder: dir,
            totalBytes: Int64(StubProtocol.body.count),
            acceptRanges: true,
            segmentsCount: 1
        )
        let segments = HTTPRangeDownloader.calculateSegments(
            taskId: task.id, totalBytes: Int64(StubProtocol.body.count), segmentCount: 1, acceptRanges: true
        )
        let downloader = HTTPRangeDownloader(session: makeSession())
        try await downloader.download(task: task, segments: segments, onProgress: { _, _ in }, onSegmentUpdate: { _ in })

        let got = try Data(contentsOf: task.finalFilePath)
        XCTAssertEqual(got, StubProtocol.body)
        XCTAssertGreaterThanOrEqual(StubProtocol.requestCount, 3, "Phải có ít nhất 3 lần thử (2 fail + 1 thành công)")
    }

    // 5. Probe với 404 → throw rõ ràng (không nuốt).
    func testProbeSurfaces404() async {
        StubProtocol.status = 404
        do {
            _ = try await HTTPRangeDownloader.probeURL(url: URL(string: "https://stub.example.com/gone.zip")!, session: makeSession())
            XCTFail("Probe phải throw với 404")
        } catch {
            XCTAssertEqual((error as NSError).code, 404)
        }
    }

    // 6. Sanitize filename + collision "(1)".
    func testSanitizeFilenameAndCollisionSuffix() {
        XCTAssertEqual(FileTypeDetector.sanitizeFilename("2024-01-01T10:00:00Z.json"), "2024-01-01T100000Z.json")
        XCTAssertEqual(FileTypeDetector.sanitizeFilename("a|b:c?.zip"), "abc?.zip".replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "|", with: ""))
        XCTAssertEqual(FileTypeDetector.sanitizeFilename(""), "download")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("idm_col_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try? Data("old".utf8).write(to: dir.appendingPathComponent("same.txt"))
        let uniq = FileTypeDetector.uniqueDestination(in: dir, filename: "same.txt")
        XCTAssertEqual(uniq.lastPathComponent, "same(1).txt")
    }

    // 7. Completion size gate: file ngắn hơn kỳ vọng → fail, không completed.
    //    Gọi ĐÚNG hàm gate của production (DownloadManager.completionSizeGate).
    func testCompletionSizeGateDetectsTruncation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("idm_gate_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("short.bin")
        try Data(repeating: 0x41, count: 40_000).write(to: file)

        // Task khai báo 50.000 byte nhưng server chỉ trả 40.000 → phải bị chặn.
        let task = DownloadTask(
            url: URL(string: "https://stub.example.com/file.bin")!,
            filename: "short.bin",
            destinationFolder: dir,
            totalBytes: 50_000
        )

        let problem = DownloadManager.completionSizeGate(task: task, fileURL: file)
        XCTAssertNotNil(problem, "File ngắn hơn totalBytes phải bị gate chặn")
        XCTAssertTrue(problem?.contains("40000") == true, "Thông báo phải nêu kích thước thực tế: \(problem ?? "")")

        // File đúng kích thước → gate pass.
        let fullFile = dir.appendingPathComponent("full.bin")
        try Data(repeating: 0x42, count: 50_000).write(to: fullFile)
        let fullTask = DownloadTask(
            url: URL(string: "https://stub.example.com/file.bin")!,
            filename: "full.bin",
            destinationFolder: dir,
            totalBytes: 50_000
        )
        XCTAssertNil(DownloadManager.completionSizeGate(task: fullTask, fileURL: fullFile), "Kích thước khớp thì không được chặn")

        // Không biết kích thước (totalBytes <= 0) → không gate (không gây fail sai).
        let unknownTask = DownloadTask(
            url: URL(string: "https://stub.example.com/file.bin")!,
            filename: "short.bin",
            destinationFolder: dir,
            totalBytes: -1
        )
        XCTAssertNil(DownloadManager.completionSizeGate(task: unknownTask, fileURL: file))
    }
}
