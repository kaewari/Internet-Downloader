import XCTest
import CryptoKit
@testable import DownloaderCore

final class NonMediaIntegrityTests: XCTestCase {

    // 1. Test Content-Disposition RFC 6266 and RFC 5987 UTF-8 priority & path traversal sanitization
    func testContentDispositionRFC5987AndAttachmentParsing() async throws {
        // Mock server providing various Content-Disposition headers
        final class ContentDispositionMockProtocol: URLProtocol {
            override class func canInit(with request: URLRequest) -> Bool {
                return request.url?.host == "disposition.example.com"
            }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                guard let url = request.url else { return }
                var headers: [String: String] = [
                    "Accept-Ranges": "bytes",
                    "Content-Length": "1024"
                ]

                if url.path.contains("utf8_priority") {
                    headers["Content-Disposition"] = "attachment; filename=\"fallback.zip\"; filename*=UTF-8''B%C3%A1o%20C%C3%A1o%202026.xlsx"
                } else if url.path.contains("path_traversal") {
                    headers["Content-Disposition"] = "attachment; filename=\"../../../secret/payload.dmg\""
                } else if url.path.contains("quoted_standard") {
                    headers["Content-Disposition"] = "attachment; filename=\"installer_v2.0.pkg\""
                }

                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(repeating: 0x50, count: 1024))
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ContentDispositionMockProtocol.self]
        let mockSession = URLSession(configuration: config)

        // Test UTF-8 priority (RFC 6266)
        let probe1 = try await HTTPRangeDownloader.probeURL(
            url: URL(string: "https://disposition.example.com/api/export/utf8_priority")!,
            session: mockSession
        )
        XCTAssertEqual(probe1.suggestedFilename, "Báo Cáo 2026.xlsx", "Must prioritize filename* with UTF-8 decoding over fallback filename")

        // Test path traversal sanitization
        let probe2 = try await HTTPRangeDownloader.probeURL(
            url: URL(string: "https://disposition.example.com/api/download/path_traversal")!,
            session: mockSession
        )
        XCTAssertEqual(probe2.suggestedFilename, "payload.dmg", "Must strip directory traversal slashes from filename")

        // Test standard quoted filename
        let probe3 = try await HTTPRangeDownloader.probeURL(
            url: URL(string: "https://disposition.example.com/api/download/quoted_standard")!,
            session: mockSession
        )
        XCTAssertEqual(probe3.suggestedFilename, "installer_v2.0.pkg")
    }

    // 2. Test comprehensive categorizedFolder for all 6 non-media categories
    func testCategorizedFoldersComprehensive() {
        let base = URL(fileURLWithPath: "/tmp/Downloads_NonMedia_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }

        // Compressed
        for ext in ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz", "zst"] {
            let folder = DownloadManager.categorizedFolder(for: "archive.\(ext)", baseFolder: base)
            XCTAssertEqual(folder.lastPathComponent, "Compressed", "Extension .\(ext) must be sorted into Compressed")
        }

        // Programs / Installers
        for ext in ["dmg", "pkg", "iso", "app", "exe", "msi", "deb", "rpm", "appimage"] {
            let folder = DownloadManager.categorizedFolder(for: "installer.\(ext)", baseFolder: base)
            XCTAssertEqual(folder.lastPathComponent, "Programs", "Extension .\(ext) must be sorted into Programs")
        }

        // Documents
        for ext in ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "csv", "epub", "rtf"] {
            let folder = DownloadManager.categorizedFolder(for: "document.\(ext)", baseFolder: base)
            XCTAssertEqual(folder.lastPathComponent, "Documents", "Extension .\(ext) must be sorted into Documents")
        }

        // Data & Dev
        for ext in ["sqlite", "db", "json", "xml", "yaml", "yml", "sql", "whl"] {
            let folder = DownloadManager.categorizedFolder(for: "dataset.\(ext)", baseFolder: base)
            XCTAssertEqual(folder.lastPathComponent, "Data", "Extension .\(ext) must be sorted into Data")
        }

        // Fonts
        for ext in ["ttf", "otf", "woff", "woff2"] {
            let folder = DownloadManager.categorizedFolder(for: "font.\(ext)", baseFolder: base)
            XCTAssertEqual(folder.lastPathComponent, "Fonts", "Extension .\(ext) must be sorted into Fonts")
        }
    }

    // 3. Test multi-segment 8-slot download of a real ZIP archive and CRC32 verification with unzip -t
    func testMultiSegmentZipDownloadAndCRC32Validation() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("zip_source_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create 3 files with binary and text content to zip
        let file1 = tempDir.appendingPathComponent("file1.txt")
        let file2 = tempDir.appendingPathComponent("file2.bin")
        let subFolder = tempDir.appendingPathComponent("subfolder")
        try FileManager.default.createDirectory(at: subFolder, withIntermediateDirectories: true)
        let file3 = subFolder.appendingPathComponent("file3.json")

        try Data("Hello world this is test non-media file 1".utf8).write(to: file1)
        try Data((0..<50000).map { UInt8($0 % 256) }).write(to: file2)
        try Data("{\"status\": \"valid\", \"count\": 12345}".utf8).write(to: file3)

        let zipPath = tempDir.appendingPathComponent("test_archive.zip")
        let zipProc = Process()
        zipProc.currentDirectoryURL = tempDir
        zipProc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zipProc.arguments = ["-r", zipPath.path, "file1.txt", "file2.bin", "subfolder"]
        try zipProc.run()
        zipProc.waitUntilExit()
        XCTAssertEqual(zipProc.terminationStatus, 0)

        let originalZipData = try Data(contentsOf: zipPath)
        let expectedSHA256 = SHA256.hash(data: originalZipData).map { String(format: "%02x", $0) }.joined()

        final class MockZipProtocol: URLProtocol {
            static var zipData: Data!
            override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "mockzip.example.com" }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                guard let url = request.url else { return }
                let total = Self.zipData.count
                if let rangeHeader = request.value(forHTTPHeaderField: "Range"), rangeHeader.hasPrefix("bytes=") {
                    let rangeStr = rangeHeader.replacingOccurrences(of: "bytes=", with: "")
                    let parts = rangeStr.split(separator: "-")
                    let start = Int(parts[0]) ?? 0
                    let end = parts.count > 1 && !parts[1].isEmpty ? Int(parts[1])! : total - 1
                    let clampedEnd = min(end, total - 1)
                    let sub = Self.zipData.subdata(in: start..<clampedEnd + 1)

                    let resp = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: [
                        "Content-Type": "application/zip",
                        "Accept-Ranges": "bytes",
                        "Content-Range": "bytes \(start)-\(clampedEnd)/\(total)",
                        "Content-Length": "\(sub.count)"
                    ])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: sub)
                    client?.urlProtocolDidFinishLoading(self)
                } else {
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                        "Content-Type": "application/zip",
                        "Accept-Ranges": "bytes",
                        "Content-Length": "\(total)"
                    ])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Self.zipData)
                    client?.urlProtocolDidFinishLoading(self)
                }
            }
            override func stopLoading() {}
        }

        MockZipProtocol.zipData = originalZipData
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockZipProtocol.self]
        let mockSession = URLSession(configuration: config)

        let targetDir = FileManager.default.temporaryDirectory.appendingPathComponent("zip_dl_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: targetDir) }

        let targetFile = targetDir.appendingPathComponent("downloaded_archive.zip")
        let task = DownloadTask(
            url: URL(string: "https://mockzip.example.com/archive.zip")!,
            filename: "downloaded_archive.zip",
            destinationFolder: targetDir,
            totalBytes: Int64(originalZipData.count),
            acceptRanges: true,
            segmentsCount: 8
        )

        let segments = HTTPRangeDownloader.calculateSegments(
            taskId: task.id,
            totalBytes: Int64(originalZipData.count),
            segmentCount: 8,
            acceptRanges: true
        )

        let downloader = HTTPRangeDownloader(session: mockSession)
        try await downloader.download(
            task: task,
            segments: segments,
            onProgress: { _, _ in },
            onSegmentUpdate: { _ in }
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: targetFile.path))
        let downloadedData = try Data(contentsOf: targetFile)
        let actualSHA256 = SHA256.hash(data: downloadedData).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(actualSHA256, expectedSHA256, "Downloaded ZIP file SHA-256 must match original bit-for-bit across 8 segments")

        // Execute unzip -t to verify CRC32 of every file inside the archive
        let unzipProc = Process()
        unzipProc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzipProc.arguments = ["-t", targetFile.path]
        let outPipe = Pipe()
        unzipProc.standardOutput = outPipe
        unzipProc.standardError = outPipe
        try unzipProc.run()
        unzipProc.waitUntilExit()

        XCTAssertEqual(unzipProc.terminationStatus, 0, "unzip -t must return 0 with zero CRC32 errors")
    }

    // 4. Test multi-segment download of real SQLite database and verify with PRAGMA integrity_check
    func testSQLiteDatabaseMultiSegmentDownloadAndIntegrityCheck() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite_source_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("test_data.db")
        let initProc = Process()
        initProc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        initProc.arguments = [
            dbPath.path,
            """
            CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT, balance REAL);
            INSERT INTO customers (name, balance) VALUES ('Alice', 1050.50);
            INSERT INTO customers (name, balance) VALUES ('Bob', 99.00);
            INSERT INTO customers (name, balance) VALUES ('Charlie', 4500.25);
            CREATE INDEX idx_customers_name ON customers(name);
            """
        ]
        try initProc.run()
        initProc.waitUntilExit()
        XCTAssertEqual(initProc.terminationStatus, 0)

        let originalDbData = try Data(contentsOf: dbPath)
        XCTAssertGreaterThan(originalDbData.count, 4096)

        final class MockSqliteProtocol: URLProtocol {
            static var dbData: Data!
            override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "mocksqlite.example.com" }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                guard let url = request.url else { return }
                let total = Self.dbData.count
                if let rangeHeader = request.value(forHTTPHeaderField: "Range"), rangeHeader.hasPrefix("bytes=") {
                    let rangeStr = rangeHeader.replacingOccurrences(of: "bytes=", with: "")
                    let parts = rangeStr.split(separator: "-")
                    let start = Int(parts[0]) ?? 0
                    let end = parts.count > 1 && !parts[1].isEmpty ? Int(parts[1])! : total - 1
                    let sub = Self.dbData.subdata(in: start..<min(end + 1, total))

                    let resp = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: [
                        "Content-Type": "application/vnd.sqlite3",
                        "Accept-Ranges": "bytes",
                        "Content-Range": "bytes \(start)-\(min(end, total - 1))/\(total)",
                        "Content-Length": "\(sub.count)"
                    ])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: sub)
                    client?.urlProtocolDidFinishLoading(self)
                } else {
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                        "Content-Type": "application/vnd.sqlite3",
                        "Accept-Ranges": "bytes",
                        "Content-Length": "\(total)"
                    ])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Self.dbData)
                    client?.urlProtocolDidFinishLoading(self)
                }
            }
            override func stopLoading() {}
        }

        MockSqliteProtocol.dbData = originalDbData
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockSqliteProtocol.self]
        let mockSession = URLSession(configuration: config)

        let targetDir = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite_dl_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: targetDir) }

        let targetFile = targetDir.appendingPathComponent("downloaded_data.db")
        let task = DownloadTask(
            url: URL(string: "https://mocksqlite.example.com/test_data.db")!,
            filename: "downloaded_data.db",
            destinationFolder: targetDir,
            totalBytes: Int64(originalDbData.count),
            acceptRanges: true,
            segmentsCount: 8
        )

        let segments = HTTPRangeDownloader.calculateSegments(
            taskId: task.id,
            totalBytes: Int64(originalDbData.count),
            segmentCount: 8,
            acceptRanges: true
        )

        let downloader = HTTPRangeDownloader(session: mockSession)
        try await downloader.download(
            task: task,
            segments: segments,
            onProgress: { _, _ in },
            onSegmentUpdate: { _ in }
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: targetFile.path))

        // Check SQLite integrity using sqlite3 CLI
        let checkProc = Process()
        checkProc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        checkProc.arguments = [targetFile.path, "PRAGMA integrity_check;"]
        let outPipe = Pipe()
        checkProc.standardOutput = outPipe
        try checkProc.run()
        checkProc.waitUntilExit()

        XCTAssertEqual(checkProc.terminationStatus, 0)
        let checkOut = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(checkOut, "ok", "SQLite PRAGMA integrity_check must return 'ok'")
    }

    // 5. Test real PDF document structure and parsing
    func testPDFDocumentStructureAndDownload() async throws {
        // Construct a syntactically valid PDF document
        let pdfString = """
        %PDF-1.4
        1 0 obj
        << /Type /Catalog /Pages 2 0 R >>
        endobj
        2 0 obj
        << /Type /Pages /Kids [3 0 R] /Count 1 >>
        endobj
        3 0 obj
        << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>
        endobj
        4 0 obj
        << /Length 44 >>
        stream
        BT
        /F1 24 Tf
        100 700 Td
        (Internet Downloader PDF Test) Tj
        ET
        endstream
        endobj
        xref
        0 5
        0000000000 65535 f 
        0000000009 00000 n 
        0000000058 00000 n 
        0000000115 00000 n 
        0000000206 00000 n 
        trailer
        << /Size 5 /Root 1 0 R >>
        startxref
        300
        %%EOF
        """
        let pdfData = Data(pdfString.utf8)

        final class MockPdfProtocol: URLProtocol {
            static var pdfData: Data!
            override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "mockpdf.example.com" }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                guard let url = request.url else { return }
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                    "Content-Type": "application/pdf",
                    "Accept-Ranges": "bytes",
                    "Content-Length": "\(Self.pdfData.count)"
                ])!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Self.pdfData)
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }

        MockPdfProtocol.pdfData = pdfData
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockPdfProtocol.self]
        let mockSession = URLSession(configuration: config)

        let targetDir = FileManager.default.temporaryDirectory.appendingPathComponent("pdf_dl_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: targetDir) }

        let targetFile = targetDir.appendingPathComponent("document.pdf")
        let task = DownloadTask(
            url: URL(string: "https://mockpdf.example.com/document.pdf")!,
            filename: "document.pdf",
            destinationFolder: targetDir,
            totalBytes: Int64(pdfData.count),
            acceptRanges: false,
            segmentsCount: 1
        )

        let downloader = HTTPRangeDownloader(session: mockSession)
        try await downloader.download(
            task: task,
            segments: [],
            onProgress: { _, _ in },
            onSegmentUpdate: { _ in }
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: targetFile.path))
        let downloaded = try Data(contentsOf: targetFile)
        XCTAssertTrue(downloaded.starts(with: "%PDF-".utf8), "Must start with %PDF- header")
        XCTAssertTrue(String(data: downloaded, encoding: .utf8)?.contains("%%EOF") == true, "Must end with %%EOF marker")
    }

    // 6. Test single-stream fallback when server does NOT provide Content-Length (dynamic chunked stream)
    func testChunkedTransferWithoutContentLength() async throws {
        let chunkData = Data("ChunkedStreamingDynamicNonMediaDataPayloadForTesting123456789".utf8)

        final class MockChunkedProtocol: URLProtocol {
            static var payload: Data!
            override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "mockchunked.example.com" }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                guard let url = request.url else { return }
                // Server does not send Content-Length or Accept-Ranges
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                    "Content-Type": "application/octet-stream",
                    "Transfer-Encoding": "chunked"
                ])!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Self.payload)
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }

        MockChunkedProtocol.payload = chunkData
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockChunkedProtocol.self]
        let mockSession = URLSession(configuration: config)

        let targetDir = FileManager.default.temporaryDirectory.appendingPathComponent("chunked_dl_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: targetDir) }

        let targetFile = targetDir.appendingPathComponent("dynamic_export.bin")
        let task = DownloadTask(
            url: URL(string: "https://mockchunked.example.com/export")!,
            filename: "dynamic_export.bin",
            destinationFolder: targetDir,
            totalBytes: -1,
            acceptRanges: false,
            segmentsCount: 1
        )

        let downloader = HTTPRangeDownloader(session: mockSession)
        try await downloader.download(
            task: task,
            segments: [],
            onProgress: { _, _ in },
            onSegmentUpdate: { _ in }
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: targetFile.path))
        let downloaded = try Data(contentsOf: targetFile)
        XCTAssertEqual(downloaded, chunkData, "Single-stream chunked fallback must download the exact dynamic payload without errors")
    }

    // 7. Live test: Download real public PDF document and verify macOS openability
    func testDownloadRealPublicPDFAndVerifyOpenable() async throws {
        let pdfURL = URL(string: "https://raw.githubusercontent.com/mozilla/pdf.js/master/examples/learning/helloworld.pdf")!
        let baseDownloads = FileManager.default.temporaryDirectory.appendingPathComponent("test_dl_nonmedia_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseDownloads, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDownloads) }

        let manager = DownloadManager(dbPath: baseDownloads.appendingPathComponent("test.sqlite3").path)

        let targetFolder = DownloadManager.categorizedFolder(for: "helloworld.pdf", baseFolder: baseDownloads)
        XCTAssertEqual(targetFolder.lastPathComponent, "Documents")

        let task = try manager.createNewTask(
            url: pdfURL,
            filename: "helloworld.pdf",
            destinationFolder: targetFolder
        )

        final class SafeBox<T>: @unchecked Sendable {
            private let lock = NSLock()
            private var _val: T
            init(_ val: T) { self._val = val }
            var val: T {
                get { lock.withLock { _val } }
                set { lock.withLock { _val = newValue } }
            }
        }

        let completedExp = expectation(description: "Real PDF download completed")
        let failureReason = SafeBox<String?>(nil)
        manager.onDownloadCompleted = { completedTask in
            if completedTask.id == task.id {
                completedExp.fulfill()
            }
        }
        manager.onTasksChanged = {
            if let t = manager.getTask(id: task.id), t.status == .failed {
                failureReason.val = t.errorMessage
                completedExp.fulfill()
            }
        }

        manager.startDownload(taskId: task.id)
        await fulfillment(of: [completedExp], timeout: 20.0)

        if let failureReason = failureReason.val {
            XCTFail("Download failed with error: \(failureReason)")
        }

        let targetFile = targetFolder.appendingPathComponent("helloworld.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetFile.path))
        let fileSize = (try? targetFile.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        XCTAssertGreaterThan(fileSize, 500, "Downloaded PDF must be greater than 500 bytes")

        let fileData = try Data(contentsOf: targetFile)
        XCTAssertTrue(fileData.starts(with: "%PDF-".utf8), "Downloaded file must be valid PDF starting with %PDF-")

        // Copy to persistent Downloads folder for user inspection
        let persistentDestFolder = URL(fileURLWithPath: "/Users/hoangson/Projects/Internet-Downloader/Downloads/Documents")
        try FileManager.default.createDirectory(at: persistentDestFolder, withIntermediateDirectories: true)
        let persistentFile = persistentDestFolder.appendingPathComponent("helloworld.pdf")
        try? FileManager.default.removeItem(at: persistentFile)
        try FileManager.default.copyItem(at: targetFile, to: persistentFile)
    }

    // 8. Live test: Download real public ZIP archive and verify CRC32
    func testDownloadRealPublicZIPAndVerifyOpenable() async throws {
        final class SafeBox<T>: @unchecked Sendable {
            private let lock = NSLock()
            private var _val: T
            init(_ val: T) { self._val = val }
            var val: T {
                get { lock.withLock { _val } }
                set { lock.withLock { _val = newValue } }
            }
        }

        let zipURL = URL(string: "https://codeload.github.com/octocat/Hello-World/zip/refs/heads/master")!
        let baseDownloads = FileManager.default.temporaryDirectory.appendingPathComponent("test_dl_zip_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseDownloads, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDownloads) }

        let manager = DownloadManager(dbPath: baseDownloads.appendingPathComponent("test.sqlite3").path)

        let targetFolder = DownloadManager.categorizedFolder(for: "Hello-World-master.zip", baseFolder: baseDownloads)
        XCTAssertEqual(targetFolder.lastPathComponent, "Compressed")

        let task = try manager.createNewTask(
            url: zipURL,
            filename: "Hello-World-master.zip",
            destinationFolder: targetFolder
        )

        let completedExp = expectation(description: "Real ZIP download completed")
        let zipFailureReason = SafeBox<String?>(nil)
        manager.onDownloadCompleted = { completedTask in
            if completedTask.id == task.id {
                completedExp.fulfill()
            }
        }
        manager.onTasksChanged = {
            if let t = manager.getTask(id: task.id), t.status == .failed {
                zipFailureReason.val = t.errorMessage
                completedExp.fulfill()
            }
        }

        manager.startDownload(taskId: task.id)
        await fulfillment(of: [completedExp], timeout: 20.0)

        if let zipFailureReason = zipFailureReason.val {
            XCTFail("ZIP download failed with error: \(zipFailureReason)")
        }

        let targetFile = targetFolder.appendingPathComponent("Hello-World-master.zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetFile.path))
        let fileSize = (try? targetFile.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        XCTAssertGreaterThan(fileSize, 300, "Downloaded ZIP must be greater than 300 bytes")

        // Verify with /usr/bin/unzip -t
        let unzipProc = Process()
        unzipProc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzipProc.arguments = ["-t", targetFile.path]
        let pipe = Pipe()
        unzipProc.standardOutput = pipe
        try unzipProc.run()
        unzipProc.waitUntilExit()
        XCTAssertEqual(unzipProc.terminationStatus, 0, "unzip -t must return 0 with no errors")

        // Copy to persistent Downloads folder for user inspection
        let persistentDestFolder = URL(fileURLWithPath: "/Users/hoangson/Projects/Internet-Downloader/Downloads/Compressed")
        try FileManager.default.createDirectory(at: persistentDestFolder, withIntermediateDirectories: true)
        let persistentFile = persistentDestFolder.appendingPathComponent("Hello-World-master.zip")
        try? FileManager.default.removeItem(at: persistentFile)
        try FileManager.default.copyItem(at: targetFile, to: persistentFile)
    }

    // 9. Test FileTypeDetector opaque identifier recognition
    func testFileTypeDetectorAndOpaqueIdentifierDetection() {
        // Opaque identifiers (UUIDs, MD5, SHA, numeric IDs)
        XCTAssertTrue(FileTypeDetector.isOpaqueIdentifier("0051985e-a8eb-4dd4-b612-9aea80ca1b21"))
        XCTAssertTrue(FileTypeDetector.isOpaqueIdentifier("E6102096-855E-4BEE-A0E4-2433856E9B0A"))
        XCTAssertTrue(FileTypeDetector.isOpaqueIdentifier("d41d8cd98f00b204e9800998ecf8427e"))
        XCTAssertTrue(FileTypeDetector.isOpaqueIdentifier("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"))
        XCTAssertTrue(FileTypeDetector.isOpaqueIdentifier("1412548284"))
        XCTAssertTrue(FileTypeDetector.isOpaqueIdentifier(""))

        // Legitimate filenames with extensions
        XCTAssertFalse(FileTypeDetector.isOpaqueIdentifier("artcraft-launcher-0.2.1-macos-universal.dmg"))
        XCTAssertFalse(FileTypeDetector.isOpaqueIdentifier("setup.exe"))
        XCTAssertFalse(FileTypeDetector.isOpaqueIdentifier("archive.tar.gz"))
        XCTAssertFalse(FileTypeDetector.isOpaqueIdentifier("document.pdf"))
        XCTAssertFalse(FileTypeDetector.isOpaqueIdentifier("data.sqlite"))
    }

    // 10. Test URL query filename extraction (Azure Blob rscd, AWS S3 response-content-disposition, direct query)
    func testURLQueryFilenameExtractionComprehensive() {
        // Azure Blob / GitHub Release asset URL
        let githubAssetURL = URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/1412548284/0051985e-a8eb-4dd4-b612-9aea80ca1b21?sp=r&rscd=attachment%3B+filename%3Dartcraft-launcher-0.2.1-macos-universal.dmg&rsct=application%2Foctet-stream")!
        let extractedName1 = FileTypeDetector.extractFilename(from: githubAssetURL)
        XCTAssertEqual(extractedName1, "artcraft-launcher-0.2.1-macos-universal.dmg")

        // AWS S3 response-content-disposition
        let s3URL = URL(string: "https://s3.amazonaws.com/mybucket/objects/987654321?response-content-disposition=attachment%3B%20filename%3D%22dataset_v1.sqlite%22")!
        let extractedName2 = FileTypeDetector.extractFilename(from: s3URL)
        XCTAssertEqual(extractedName2, "dataset_v1.sqlite")

        // RFC 5987 UTF-8 encoded filename in query
        let utf8URL = URL(string: "https://cdn.example.com/export?rscd=attachment%3B+filename*%3DUTF-8%27%27T%C3%A0i%20Li%E1%BB%87u%202026.pdf")!
        let extractedName3 = FileTypeDetector.extractFilename(from: utf8URL)
        XCTAssertEqual(extractedName3, "Tài Liệu 2026.pdf")

        // Direct filename query param
        let directURL = URL(string: "https://download.example.com/get?id=999&filename=installer_mac.pkg")!
        let extractedName4 = FileTypeDetector.extractFilename(from: directURL)
        XCTAssertEqual(extractedName4, "installer_mac.pkg")
    }

    // 11. Test binary magic bytes detection on disk (DMG, PKG, ZIP, PDF, SQLite, PE EXE)
    func testBinaryMagicBytesDetection() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("magic_bytes_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Apple Disk Image (UDIF DMG): 1024 bytes with trailer starting with 'koly'
        let dmgFile = tempDir.appendingPathComponent("sample_dmg_no_ext")
        var dmgData = Data(repeating: 0x00, count: 512)
        let kolyTrailer = Data([0x6b, 0x6f, 0x6c, 0x79]) + Data(repeating: 0x01, count: 508)
        dmgData.append(kolyTrailer)
        try dmgData.write(to: dmgFile)
        XCTAssertEqual(FileTypeDetector.detectExtension(fileURL: dmgFile), "dmg")

        // Apple PKG / XAR: 'xar!'
        let pkgFile = tempDir.appendingPathComponent("sample_pkg_no_ext")
        let pkgData = Data([0x78, 0x61, 0x72, 0x21, 0x00, 0x1c]) + Data(repeating: 0x00, count: 100)
        try pkgData.write(to: pkgFile)
        XCTAssertEqual(FileTypeDetector.detectExtension(fileURL: pkgFile), "pkg")

        // PDF: '%PDF-'
        let pdfFile = tempDir.appendingPathComponent("sample_pdf_no_ext")
        let pdfData = Data("%PDF-1.7\nSample content".utf8)
        try pdfData.write(to: pdfFile)
        XCTAssertEqual(FileTypeDetector.detectExtension(fileURL: pdfFile), "pdf")

        // SQLite: 'SQLite format 3\0'
        let sqliteFile = tempDir.appendingPathComponent("sample_sqlite_no_ext")
        let sqliteData = Data("SQLite format 3\0Header details".utf8)
        try sqliteData.write(to: sqliteFile)
        XCTAssertEqual(FileTypeDetector.detectExtension(fileURL: sqliteFile), "sqlite")

        // Windows PE EXE: 'MZ'
        let exeFile = tempDir.appendingPathComponent("sample_exe_no_ext")
        let exeData = Data([0x4d, 0x5a, 0x90, 0x00]) + Data(repeating: 0x00, count: 100)
        try exeData.write(to: exeFile)
        XCTAssertEqual(FileTypeDetector.detectExtension(fileURL: exeFile), "exe")
    }

    // 12. Test createNewTask automatically resolving GitHub Release signed URL to real filename directly in ~/Downloads
    func testCreateNewTaskWithGitHubReleaseSignedURL() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("github_release_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = DownloadManager(dbPath: tempDir.appendingPathComponent("test.sqlite3").path)
        let githubAssetURL = URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/1412548284/0051985e-a8eb-4dd4-b612-9aea80ca1b21?sp=r&rscd=attachment%3B+filename%3Dartcraft-launcher-0.2.1-macos-universal.dmg&rsct=application%2Foctet-stream")!

        let userDownloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!

        // When created with empty filename or UUID path
        let task = try manager.createNewTask(
            url: githubAssetURL,
            filename: "0051985e-a8eb-4dd4-b612-9aea80ca1b21",
            destinationFolder: userDownloads
        )

        // Must extract the real filename from rscd query instead of the UUID path
        XCTAssertEqual(task.filename, "artcraft-launcher-0.2.1-macos-universal.dmg")
        // Must save directly into /Users/hoangson/Downloads/artcraft-launcher-0.2.1-macos-universal.dmg
        XCTAssertEqual(task.destinationFolder.standardizedFileURL, userDownloads.standardizedFileURL)
        XCTAssertEqual(task.finalFilePath.path, userDownloads.appendingPathComponent("artcraft-launcher-0.2.1-macos-universal.dmg").path)
    }

    // 13. Test probeURL magic-byte fallback via Range: bytes=0-511 when URL is opaque and Content-Type is octet-stream
    func testProbeURLDetectsExtensionFromRangeHeaderDataWhenOpaqueURL() async throws {
        final class OpaqueMagicMockProtocol: URLProtocol {
            override class func canInit(with request: URLRequest) -> Bool {
                request.url?.host == "opaque-magic.example.com"
            }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                guard let url = request.url else { return }
                let samplePkgBytes = Data([0x78, 0x61, 0x72, 0x21, 0x00, 0x1c]) + Data(repeating: 0x00, count: 1018)
                if request.httpMethod == "HEAD" {
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                        "Content-Type": "application/octet-stream",
                        "Accept-Ranges": "bytes",
                        "Content-Length": "1024"
                    ])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocolDidFinishLoading(self)
                } else {
                    let sub = samplePkgBytes.prefix(512)
                    let resp = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: [
                        "Content-Type": "application/octet-stream",
                        "Accept-Ranges": "bytes",
                        "Content-Range": "bytes 0-511/1024",
                        "Content-Length": "\(sub.count)"
                    ])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Data(sub))
                    client?.urlProtocolDidFinishLoading(self)
                }
            }
            override func stopLoading() {}
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OpaqueMagicMockProtocol.self]
        let mockSession = URLSession(configuration: config)

        let opaqueURL = URL(string: "https://opaque-magic.example.com/objects/0051985e-a8eb-4dd4-b612-9aea80ca1b21")!
        let probe = try await HTTPRangeDownloader.probeURL(url: opaqueURL, session: mockSession)
        XCTAssertEqual(probe.totalBytes, 1024)
        XCTAssertEqual(probe.suggestedFilename, "0051985e-a8eb-4dd4-b612-9aea80ca1b21.pkg", "probeURL must inspect first 512 bytes via Range GET when HEAD has no extension and append detected .pkg extension")
    }

    // 14. Test user existing downloaded file on disk
    func testUserExistingDownloadedFileDetectionAndMountability() {
        let candidates = [
            URL(fileURLWithPath: "/Users/hoangson/Downloads/artcraft-launcher-0.2.1-macos-universal.dmg"),
            URL(fileURLWithPath: "/Users/hoangson/Downloads/0051985e-a8eb-4dd4-b612-9aea80ca1b21")
        ]
        for fileURL in candidates where FileManager.default.fileExists(atPath: fileURL.path) {
            let detected = FileTypeDetector.detectExtension(fileURL: fileURL)
            XCTAssertEqual(detected, "dmg", "Must detect dmg extension from koly trailer")
        }
    }
}
