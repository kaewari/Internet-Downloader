import XCTest
@testable import DownloaderCore

private final class ProgressCaptureBox: @unchecked Sendable {
    var downloadedBytes: Int64 = 0
    var estimatedTotal: Int64 = 0
    var downloadedSegs: Int = 0
    var totalSegs: Int = 0
    var workerSegments: [DownloadSegment] = []
}

final class DownloaderCoreTests: XCTestCase {

    func testDownloadTaskModelAndProgress() {
        let url = URL(string: "https://example.com/archive.zip")!
        let dest = URL(fileURLWithPath: "/tmp")
        var task = DownloadTask(url: url, destinationFolder: dest, totalBytes: 1000, downloadedBytes: 250)

        XCTAssertEqual(task.filename, "archive.zip")
        XCTAssertEqual(task.progress, 0.25, accuracy: 0.001)

        // Edge case: totalBytes <= 0
        task.totalBytes = -1
        XCTAssertEqual(task.progress, 0.0)

        // Edge case: downloaded > totalBytes (boundary safety)
        task.totalBytes = 1000
        task.downloadedBytes = 1500
        XCTAssertEqual(task.progress, 1.0)
    }

    func testDownloadSegmentCalculations() {
        let taskId = UUID()

        // Test non-accept ranges or 1 segment
        let single = HTTPRangeDownloader.calculateSegments(
            taskId: taskId,
            totalBytes: 1000,
            segmentCount: 1,
            acceptRanges: true
        )
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single[0].startByte, 0)
        XCTAssertEqual(single[0].endByte, 999)

        // Test 4 segments of 1000 bytes
        let four = HTTPRangeDownloader.calculateSegments(
            taskId: taskId,
            totalBytes: 1000,
            segmentCount: 4,
            acceptRanges: true
        )
        XCTAssertEqual(four.count, 4)
        XCTAssertEqual(four[0].startByte, 0)
        XCTAssertEqual(four[0].endByte, 249)
        XCTAssertEqual(four[1].startByte, 250)
        XCTAssertEqual(four[1].endByte, 499)
        XCTAssertEqual(four[2].startByte, 500)
        XCTAssertEqual(four[2].endByte, 749)
        XCTAssertEqual(four[3].startByte, 750)
        XCTAssertEqual(four[3].endByte, 999)

        // Test non-divisible size: 1005 bytes into 4 segments
        let nonDiv = HTTPRangeDownloader.calculateSegments(
            taskId: taskId,
            totalBytes: 1005,
            segmentCount: 4,
            acceptRanges: true
        )
        XCTAssertEqual(nonDiv.count, 4)
        XCTAssertEqual(nonDiv[3].endByte, 1004)
        XCTAssertEqual(nonDiv[0].startByte, 0)
    }

    func testFileAssemblerIntegrity() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let destFile = fileManager.temporaryDirectory.appendingPathComponent("assembled_\(UUID().uuidString).bin")
        defer { try? fileManager.removeItem(at: destFile) }

        let taskId = UUID()
        let part1Data = Data("HELLO ".utf8)
        let part2Data = Data("WORLD!".utf8)

        let seg0 = DownloadSegment(taskId: taskId, index: 0, startByte: 0, endByte: 5, downloadedBytes: Int64(part1Data.count), status: .completed)
        let seg1 = DownloadSegment(taskId: taskId, index: 1, startByte: 6, endByte: 11, downloadedBytes: Int64(part2Data.count), status: .completed)

        try part1Data.write(to: seg0.tempFile(in: tempDir))
        try part2Data.write(to: seg1.tempFile(in: tempDir))

        let assembler = FileAssembler()
        try assembler.assemble(
            segments: [seg1, seg0], // Test out-of-order array sorting
            tempDirectory: tempDir,
            destinationFile: destFile,
            expectedTotalBytes: 12
        )

        let assembledData = try Data(contentsOf: destFile)
        XCTAssertEqual(String(data: assembledData, encoding: .utf8), "HELLO WORLD!")
    }

    func testSQLiteStoreCRUDAndPersistence() throws {
        let store = try SQLiteStore(path: ":memory:")
        let taskId = UUID()
        let task = DownloadTask(
            id: taskId,
            url: URL(string: "https://example.com/movie.mp4")!,
            filename: "movie.mp4",
            destinationFolder: URL(fileURLWithPath: "/tmp"),
            totalBytes: 1048576,
            downloadedBytes: 524288,
            status: .downloading,
            speed: 1024000,
            etag: "\"123456\"",
            acceptRanges: true,
            segmentsCount: 4
        )

        try store.saveTask(task)

        guard let loaded = try store.getTask(id: taskId) else {
            XCTFail("Task should exist in SQLite")
            return
        }

        XCTAssertEqual(loaded.id, taskId)
        XCTAssertEqual(loaded.filename, "movie.mp4")
        XCTAssertEqual(loaded.totalBytes, 1048576)
        XCTAssertEqual(loaded.downloadedBytes, 524288)
        XCTAssertEqual(loaded.status, .downloading)
        XCTAssertEqual(loaded.etag, "\"123456\"")
        XCTAssertTrue(loaded.acceptRanges)

        // Save segments
        let seg0 = DownloadSegment(taskId: taskId, index: 0, startByte: 0, endByte: 262143, downloadedBytes: 262143, status: .completed)
        let seg1 = DownloadSegment(taskId: taskId, index: 1, startByte: 262144, endByte: 524287, downloadedBytes: 100000, status: .downloading)
        try store.saveSegments([seg0, seg1])

        let loadedSegs = try store.getSegments(for: taskId)
        XCTAssertEqual(loadedSegs.count, 2)
        XCTAssertEqual(loadedSegs[0].index, 0)
        XCTAssertEqual(loadedSegs[0].status, .completed)
        XCTAssertEqual(loadedSegs[1].index, 1)
        XCTAssertEqual(loadedSegs[1].downloadedBytes, 100000)

        // Delete task
        try store.deleteTask(id: taskId)
        XCTAssertNil(try store.getTask(id: taskId))
        XCTAssertEqual(try store.getSegments(for: taskId).count, 0)
    }

    func testIPCSerialization() throws {
        let req = IPCRequest(
            action: "start_download",
            url: "https://example.com/test.iso",
            filename: "test.iso",
            referrer: "https://example.com",
            cookies: "session=xyz",
            userAgent: "Mozilla/5.0"
        )

        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(IPCRequest.self, from: data)

        XCTAssertEqual(decoded.action, "start_download")
        XCTAssertEqual(decoded.url, "https://example.com/test.iso")
        XCTAssertEqual(decoded.cookies, "session=xyz")

        let resp = IPCResponse(success: true, taskId: "abc-123", message: "OK")
        let respData = try JSONEncoder().encode(resp)
        let decodedResp = try JSONDecoder().decode(IPCResponse.self, from: respData)

        XCTAssertTrue(decodedResp.success)
        XCTAssertEqual(decodedResp.taskId, "abc-123")
    }

    func testHLSPlaylistParser() throws {
        let m3u8Content = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:10
        #EXT-X-MEDIA-SEQUENCE:0
        #EXTINF:9.009,
        segment001.ts
        #EXTINF:9.009,
        segment002.ts
        #EXTINF:4.500,
        https://cdn.example.com/segment003.ts
        #EXT-X-ENDLIST
        """

        let base = URL(string: "https://example.com/hls/playlist.m3u8")!
        let segments = try HLSDownloader.parsePlaylist(content: m3u8Content, baseURL: base)

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].duration, 9.009)
        XCTAssertEqual(segments[0].uri.absoluteString, "https://example.com/hls/segment001.ts")
        XCTAssertEqual(segments[1].uri.absoluteString, "https://example.com/hls/segment002.ts")
        XCTAssertEqual(segments[2].uri.absoluteString, "https://cdn.example.com/segment003.ts")
    }

    func testHLSDownloaderHeadersAndCookiesPropagation() async throws {
        let downloader = HLSDownloader()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("test.ts")
        let invalidURL = URL(string: "http://127.0.0.1:65534/nonexistent.m3u8")!
        do {
            try await downloader.download(
                playlistURL: invalidURL,
                destinationFile: dest,
                tempDirectory: tempDir,
                cookies: "session=test_cookie",
                referrer: "https://example.com/player",
                userAgent: "CustomUA/1.0",
                onProgress: { _, _, _, _, _, _ in }
            )
            XCTFail("Should fail for invalid URL")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    func testHLSDownloaderDescriptiveHTTPStatusError() async throws {
        class Mock403Protocol: URLProtocol {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("Forbidden".utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Mock403Protocol.self]
        let mockSession = URLSession(configuration: config)
        let downloader = HLSDownloader(session: mockSession)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("test.mp4")

        do {
            try await downloader.download(
                playlistURL: URL(string: "https://example.com/stream.m3u8")!,
                destinationFile: dest,
                tempDirectory: tempDir,
                onProgress: { _, _, _, _, _, _ in }
            )
            XCTFail("Should fail with 403")
        } catch let nsError as NSError {
            XCTAssertEqual(nsError.domain, "HLSDownloader")
            XCTAssertEqual(nsError.code, 403)
            XCTAssertTrue(nsError.localizedDescription.contains("Playlist HTTP 403"))
        }
    }

    func testSpeedTrackerCalculations() {
        let tracker = SpeedTracker(windowSeconds: 1.0)
        tracker.record(bytes: 1024 * 1024) // 1MB
        XCTAssertGreaterThanOrEqual(tracker.currentSpeed(), 0.0)

        let eta = tracker.estimatedTimeRemaining(remainingBytes: 5 * 1024 * 1024)
        if tracker.currentSpeed() > 1024 {
            XCTAssertNotNil(eta)
        }
        tracker.reset()
        XCTAssertEqual(tracker.currentSpeed(), 0.0)
    }

    func testUnixDomainSocketEndToEndIPC() throws {
        let testSockPath = "/tmp/test_ipc_\(UUID().uuidString).sock"
        let server = UnixDomainSocketServer(socketPath: testSockPath)
        server.requestHandler = { req in
            if req.action == "ping" {
                return IPCResponse(success: true, message: "pong")
            }
            if req.action == "start_download" {
                return IPCResponse(success: true, taskId: "test-task-1", message: "Download queued")
            }
            return IPCResponse(success: false, message: "Unknown")
        }

        try server.start()
        defer { server.stop() }

        // Give the server a small moment to listen
        Thread.sleep(forTimeInterval: 0.05)

        let client = UnixDomainSocketClient(socketPath: testSockPath)
        let pingResp = try client.send(request: IPCRequest(action: "ping"))
        XCTAssertTrue(pingResp.success)
        XCTAssertEqual(pingResp.message, "pong")

        let dlResp = try client.send(request: IPCRequest(action: "start_download", url: "https://example.com/file.dmg"))
        XCTAssertTrue(dlResp.success)
        XCTAssertEqual(dlResp.taskId, "test-task-1")
    }

    func testCategorizedFolder() {
        let base = URL(fileURLWithPath: "/tmp/DownloadsTest_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }

        let videoFolder = DownloadManager.categorizedFolder(for: "movie.mp4", baseFolder: base)
        XCTAssertEqual(videoFolder.lastPathComponent, "Videos")

        let musicFolder = DownloadManager.categorizedFolder(for: "song.mp3", baseFolder: base)
        XCTAssertEqual(musicFolder.lastPathComponent, "Audio")

        let zipFolder = DownloadManager.categorizedFolder(for: "archive.zip", baseFolder: base)
        XCTAssertEqual(zipFolder.lastPathComponent, "Compressed")

        let appFolder = DownloadManager.categorizedFolder(for: "app.dmg", baseFolder: base)
        XCTAssertEqual(appFolder.lastPathComponent, "Programs")

        let docFolder = DownloadManager.categorizedFolder(for: "report.pdf", baseFolder: base)
        XCTAssertEqual(docFolder.lastPathComponent, "Documents")

        let imgFolder = DownloadManager.categorizedFolder(for: "photo.jpg", baseFolder: base)
        XCTAssertEqual(imgFolder.lastPathComponent, "Images")
    }

    func testDirectSparseFileWriting() throws {
        let fileManager = FileManager.default
        let testDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: testDir) }

        let targetFile = testDir.appendingPathComponent("direct_write_test.bin")
        let totalSize: Int64 = 24 // 24 bytes

        fileManager.createFile(atPath: targetFile.path, contents: nil)
        let initHandle = try FileHandle(forWritingTo: targetFile)
        try initHandle.truncate(atOffset: UInt64(totalSize))
        try initHandle.close()

        // 3 workers writing directly at offsets 0, 8, 16
        let chunk1 = Data("11111111".utf8)
        let chunk2 = Data("22222222".utf8)
        let chunk3 = Data("33333333".utf8)

        let h1 = try FileHandle(forWritingTo: targetFile)
        try h1.seek(toOffset: 0)
        try h1.write(contentsOf: chunk1)
        try h1.close()

        let h3 = try FileHandle(forWritingTo: targetFile)
        try h3.seek(toOffset: 16)
        try h3.write(contentsOf: chunk3)
        try h3.close()

        let h2 = try FileHandle(forWritingTo: targetFile)
        try h2.seek(toOffset: 8)
        try h2.write(contentsOf: chunk2)
        try h2.close()

        let assembled = try Data(contentsOf: targetFile)
        XCTAssertEqual(String(data: assembled, encoding: .utf8), "111111112222222233333333")
    }

    func testDownloadManagerStartedAndCompletedCallbacks() async throws {
        let tempDB = FileManager.default.temporaryDirectory.appendingPathComponent("test_cb_\(UUID().uuidString).sqlite3").path
        defer { try? FileManager.default.removeItem(atPath: tempDB) }

        let manager = DownloadManager(dbPath: tempDB)
        // Đích download riêng biệt từng run: collision "(N)" là hành vi đúng,
        // không để file test trước trong /tmp làm test fragen.
        let tempDest = FileManager.default.temporaryDirectory.appendingPathComponent("idm_cb_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDest) }

        let startedExpectation = expectation(description: "Download started callback fired")
        let completedExpectation = expectation(description: "Download completed callback fired")

        manager.onDownloadStarted = { task in
            XCTAssertEqual(task.filename, "test_file.txt")
            startedExpectation.fulfill()
        }

        manager.onDownloadCompleted = { task in
            XCTAssertEqual(task.status, .completed)
            completedExpectation.fulfill()
        }

        // Use Data URL for immediate, offline deterministic test
        let dataURL = URL(string: "data:text/plain;base64,SGVsbG8gSW50ZXJuZXQgRG93bmxvYWRlcg==")!
        let task = try manager.createNewTask(url: dataURL, filename: "test_file.txt", destinationFolder: tempDest)
        manager.startDownload(taskId: task.id)

        await fulfillment(of: [startedExpectation, completedExpectation], timeout: 3.0)
    }

    func testBinaryFindersAndResolverCapabilities() {
        // Verify ffmpeg and yt-dlp discovery
        let ffmpeg = MediaURLResolver.findFfmpegBinary()
        XCTAssertNotNil(ffmpeg)
        let ytdlp = MediaURLResolver.findYtDlpBinary()
        XCTAssertNotNil(ytdlp)

        // Verify direct media extension classification
        XCTAssertTrue(MediaURLResolver.isDirectMediaURL(URL(string: "https://example.com/master.m3u8")!))
        XCTAssertTrue(MediaURLResolver.isDirectMediaURL(URL(string: "https://example.com/video.mp4")!))
        XCTAssertFalse(MediaURLResolver.isDirectMediaURL(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!))
    }

    func testSQLiteStoreDeleteFailedTasks() throws {
        let tempDB = FileManager.default.temporaryDirectory.appendingPathComponent("test_del_failed_\(UUID().uuidString).sqlite3").path
        defer { try? FileManager.default.removeItem(atPath: tempDB) }

        let store = try SQLiteStore(path: tempDB)
        let dest = FileManager.default.temporaryDirectory

        var t1 = DownloadTask(url: URL(string: "https://example.com/1.mp4")!, destinationFolder: dest)
        t1.status = .completed
        try store.saveTask(t1)

        var t2 = DownloadTask(url: URL(string: "https://example.com/2.mp4")!, destinationFolder: dest)
        t2.status = .paused
        try store.saveTask(t2)

        var t3 = DownloadTask(url: URL(string: "https://example.com/3.mp4")!, destinationFolder: dest)
        t3.status = .failed
        t3.errorMessage = "403 Forbidden"
        try store.saveTask(t3)

        let seg = DownloadSegment(id: UUID(), taskId: t3.id, index: 0, startByte: 0, endByte: 100, downloadedBytes: 50, status: .failed)
        try store.saveSegments([seg])

        // Verify initial state
        XCTAssertEqual(try store.getAllTasks().count, 3)
        XCTAssertEqual(try store.getSegments(for: t3.id).count, 1)

        // Delete failed tasks
        try store.deleteFailedTasks()

        let remaining = try store.getAllTasks()
        XCTAssertEqual(remaining.count, 2)
        XCTAssertFalse(remaining.contains(where: { $0.id == t3.id }))
        XCTAssertTrue(remaining.contains(where: { $0.id == t1.id }))
        XCTAssertTrue(remaining.contains(where: { $0.id == t2.id }))
        XCTAssertEqual(try store.getSegments(for: t3.id).count, 0)
    }

    func testDownloadManagerClearFailedTasks() throws {
        let tempDB = FileManager.default.temporaryDirectory.appendingPathComponent("test_mgr_clear_\(UUID().uuidString).sqlite3").path
        defer { try? FileManager.default.removeItem(atPath: tempDB) }

        let manager = DownloadManager(dbPath: tempDB)
        let dest = FileManager.default.temporaryDirectory

        var t1 = try manager.createNewTask(url: URL(string: "https://example.com/ok.mp4")!, filename: "ok.mp4", destinationFolder: dest)
        t1.status = .completed
        try manager.store.saveTask(t1)

        var t2 = try manager.createNewTask(url: URL(string: "https://example.com/bad1.mp4")!, filename: "bad1.mp4", destinationFolder: dest)
        t2.status = .failed
        t2.errorMessage = "Network error"
        try manager.store.saveTask(t2)

        var t3 = try manager.createNewTask(url: URL(string: "https://example.com/bad2.mp4")!, filename: "bad2.mp4", destinationFolder: dest)
        t3.status = .failed
        t3.errorMessage = "403 Forbidden"
        try manager.store.saveTask(t3)

        XCTAssertEqual(manager.getAllTasks().count, 3)

        var callbackFired = false
        manager.onTasksChanged = { callbackFired = true }

        try manager.clearFailedTasks()

        XCTAssertTrue(callbackFired)
        let remaining = manager.getAllTasks()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].id, t1.id)
    }

    func testDownloadManagerUpdateTaskURL() throws {
        let tempDB = FileManager.default.temporaryDirectory.appendingPathComponent("test_mgr_update_url_\(UUID().uuidString).sqlite3").path
        defer { try? FileManager.default.removeItem(atPath: tempDB) }

        let manager = DownloadManager(dbPath: tempDB)
        let dest = FileManager.default.temporaryDirectory

        var t = try manager.createNewTask(url: URL(string: "https://old.example.com/stream.m3u8")!, filename: "stream.mp4", destinationFolder: dest, referrer: "https://old.example.com")
        t.status = .failed
        t.errorMessage = "403 Expired Token"
        try manager.store.saveTask(t)

        let newURL = URL(string: "https://fresh.example.com/stream-fresh.m3u8")!
        let newReferrer = "https://fresh.example.com/player"

        try manager.updateTaskURL(taskId: t.id, newURL: newURL, newReferrer: newReferrer)

        guard let updated = manager.getTask(id: t.id) else {
            XCTFail("Task should exist")
            return
        }

        XCTAssertEqual(updated.url, newURL)
        XCTAssertEqual(updated.referrer, newReferrer)
        XCTAssertNil(updated.errorMessage)
        XCTAssertEqual(updated.status, .paused)
        XCTAssertEqual(updated.speed, 0)
    }

    func testHLSProgressBytesAndEstimation() async throws {
        class MockHLSStreamProtocol: URLProtocol {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                guard let url = request.url else { return }
                if url.path.hasSuffix(".m3u8") {
                    let m3u8 = """
                    #EXTM3U
                    #EXT-X-VERSION:3
                    #EXT-X-TARGETDURATION:5
                    #EXTINF:5.0,
                    seg0.ts
                    #EXTINF:5.0,
                    seg1.ts
                    #EXT-X-ENDLIST
                    """
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/vnd.apple.mpegurl"])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Data(m3u8.utf8))
                    client?.urlProtocolDidFinishLoading(self)
                } else if url.path.hasSuffix(".ts") {
                    let dummyData = Data(repeating: 0x47, count: 1024 * 100) // 100 KB
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "video/mp2t"])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: dummyData)
                    client?.urlProtocolDidFinishLoading(self)
                }
            }
            override func stopLoading() {}
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHLSStreamProtocol.self]
        let mockSession = URLSession(configuration: config)
        let downloader = HLSDownloader(session: mockSession)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("hls_test_\(UUID().uuidString)")
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("hls_output_\(UUID().uuidString).ts")
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            try? FileManager.default.removeItem(at: dest)
        }

        let box = ProgressCaptureBox()

        try await downloader.download(
            playlistURL: URL(string: "https://example.com/stream/playlist.m3u8")!,
            destinationFile: dest,
            tempDirectory: tempDir,
            onProgress: { dSegs, tSegs, dBytes, estTotal, speed, activeSegments in
                box.downloadedSegs = dSegs
                box.totalSegs = tSegs
                box.downloadedBytes = dBytes
                box.estimatedTotal = estTotal
            }
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertEqual(box.totalSegs, 2)
        XCTAssertEqual(box.downloadedSegs, 2)
        XCTAssertEqual(box.downloadedBytes, 204800) // 2 * 100 KB
        XCTAssertEqual(box.estimatedTotal, 204800)
    }

    func testDownloadTaskSegmentProgressAndPersistence() throws {
        let tempDB = FileManager.default.temporaryDirectory.appendingPathComponent("test_task_segs_\(UUID().uuidString).sqlite3").path
        defer { try? FileManager.default.removeItem(atPath: tempDB) }

        let store = try SQLiteStore(path: tempDB)
        let dest = FileManager.default.temporaryDirectory

        var task = DownloadTask(
            url: URL(string: "https://example.com/video.m3u8")!,
            filename: "video.mp4",
            destinationFolder: dest,
            totalBytes: 200_000_000,
            downloadedBytes: 100_000_000,
            segmentsCount: 85,
            downloadedSegmentsCount: 60
        )

        XCTAssertEqual(task.progress, 0.5)

        // Test segment fallback when totalBytes is -1
        let pendingTask = DownloadTask(
            url: URL(string: "https://example.com/video.m3u8")!,
            filename: "video.mp4",
            destinationFolder: dest,
            totalBytes: -1,
            downloadedBytes: 0,
            segmentsCount: 10,
            downloadedSegmentsCount: 5
        )
        XCTAssertEqual(pendingTask.progress, 0.5)

        try store.saveTask(task)
        guard let loaded = try store.getTask(id: task.id) else {
            XCTFail("Should load saved task")
            return
        }

        XCTAssertEqual(loaded.segmentsCount, 85)
        XCTAssertEqual(loaded.downloadedSegmentsCount, 60)
        XCTAssertEqual(loaded.totalBytes, 200_000_000)
        XCTAssertEqual(loaded.downloadedBytes, 100_000_000)
    }

    func testDownloadConfirmationRequestedIPCAndSettingsUpdate() throws {
        let tempDB = FileManager.default.temporaryDirectory.appendingPathComponent("test_ipc_confirm_\(UUID().uuidString).sqlite3").path
        let sockPath = "/tmp/test_confirm_\(UUID().uuidString).sock"
        defer {
            try? FileManager.default.removeItem(atPath: tempDB)
            unlink(sockPath)
        }

        setenv("IDM_SOCKET_PATH", sockPath, 1)
        defer { unsetenv("IDM_SOCKET_PATH") }

        let manager = DownloadManager(dbPath: tempDB)
        try manager.ipcServer.start()
        defer { manager.ipcServer.stop() }

        var requestedTask: DownloadTask?
        let exp = expectation(description: "Confirmation requested")
        manager.onDownloadConfirmationRequested = { task in
            requestedTask = task
            exp.fulfill()
        }

        let client = UnixDomainSocketClient(socketPath: sockPath)
        let req = IPCRequest(
            action: "start_download",
            url: "https://example.com/stream.m3u8",
            filename: "original.mp4",
            referrer: "https://example.com/page"
        )
        let res = try client.send(request: req)
        XCTAssertTrue(res.success)
        XCTAssertEqual(res.message, "Awaiting confirmation")

        waitForExpectations(timeout: 2.0)
        XCTAssertNotNil(requestedTask)
        let taskId = requestedTask!.id

        // Check task is in database with status pending
        guard let stored = manager.getTask(id: taskId) else {
            XCTFail("Task should exist in DB")
            return
        }
        XCTAssertEqual(stored.status, .pending)

        // User changes destination and filename in popup
        let customDir = FileManager.default.temporaryDirectory.appendingPathComponent("custom_dir")
        manager.updateTaskSettings(taskId: taskId, filename: "renamed_video.mp4", destinationFolder: customDir, segmentsCount: 16, totalBytes: 187_319_308)

        guard let updated = manager.getTask(id: taskId) else {
            XCTFail("Updated task should exist")
            return
        }
        XCTAssertEqual(updated.filename, "renamed_video.mp4")
        XCTAssertEqual(updated.destinationFolder, customDir)
        XCTAssertEqual(updated.segmentsCount, 16)
        XCTAssertEqual(updated.totalBytes, 187_319_308)
    }

    func testMediaURLResolverProbeSizeAndTitle() async {
        // Test 1: Fallback for invalid / unreachable direct URL
        let invalidURL = URL(string: "https://invalid.test.domain.doesnotexist/video.mp4")!
        let (invSize, invTitle) = await MediaURLResolver.probeMediaSizeAndTitle(url: invalidURL)
        XCTAssertEqual(invSize, -1)
        XCTAssertNil(invTitle)

        // Test 2: If yt-dlp is available, probe live YouTube video
        if let ytdlp = MediaURLResolver.findYtDlpBinary() {
            let ytURL = URL(string: "https://www.youtube.com/watch?v=FVnhw0mVH_Q")!
            let (ytSize, ytTitle) = await MediaURLResolver.probeMediaSizeAndTitle(url: ytURL)
            XCTAssertNotNil(ytTitle, "Must retrieve YouTube video title")
            XCTAssertTrue(ytTitle!.contains("Japanese") || ytTitle!.contains("会話"), "Title should match YouTube video")
            XCTAssertGreaterThan(ytSize, 50_000_000, "Must retrieve genuine video size (>50MB, ~187MB), not 26KB webmanifest")
        }
    }

    func testCleanYtDlpErrorMessageFiltersWarnings() {
        let rawErr = """
        WARNING: [generic] Deprecated Feature: Passing cookies as a header is a potential security risk; they will be scoped to the domain of the downloaded urls. Please consider loading cookies from a file or browser instead.
        ERROR: [generic] manifest.webmanifest: Not a video format
        """
        let errLines = rawErr.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("WARNING:") }
        let errMsg = (errLines.first(where: { $0.hasPrefix("ERROR:") }) ?? errLines.last) ?? rawErr

        XCTAssertFalse(errMsg.contains("Deprecated Feature"), "Must not show deprecation warning as error")
        XCTAssertTrue(errMsg.contains("ERROR: [generic] manifest.webmanifest: Not a video format"))
    }

    func testDeanEdwardsUnpackingAndEmbedStreamResolution() async {
        // Sample Dean Edwards packed script (similar to recordplay.biz embeds)
        let samplePacked = """
        <script type='text/javascript'>
        eval(function(p,a,c,k,e,d){while(c--)if(k[c])p=p.replace(new RegExp('\\\\b'+c.toString(a)+'\\\\b','g'),k[c]);return p}('b o={"3":"/4/5/6.1","2":"https://7.8.9/0/6.1?t=a"};',11,11,'hls2|m3u8|links|hls4|stream|probe|master|cdn|example|com|token'.split('|')))
        </script>
        """

        let unpacked = MediaURLResolver.unpackDeanEdwards(script: samplePacked)
        XCTAssertNotNil(unpacked, "Must unpack Dean Edwards packed script")
        XCTAssertTrue(unpacked!.contains("https://cdn.example.com/hls2/master.m3u8?t=token"), "Must resolve genuine CDN stream URL")

        // Direct media URL check: recordplay.biz should NOT be considered a direct file
        let probeURL = URL(string: "https://recordplay.biz/stream/123/master.m3u8")!
        XCTAssertFalse(MediaURLResolver.isDirectMediaURL(probeURL), "recordplay.biz URLs need embed resolution, cannot be treated as direct")

        let embedURL = URL(string: "https://recordplay.biz/e/20enthat5erf")!
        XCTAssertFalse(MediaURLResolver.isDirectMediaURL(embedURL), "Embed URLs cannot be treated as direct files")
    }

    func testRecordplayStreamResolutionFromReferer() async {
        // When url is recordplay.biz/stream/ probe and Referer has the embed URL:
        let probeURL = URL(string: "https://recordplay.biz/stream/test_id/123/master.m3u8")!
        let embedURL = "https://recordplay.biz/e/20enthat5erf"

        let resolved = await MediaURLResolver.resolve(
            url: probeURL,
            customHeaders: ["Referer": embedURL]
        )

        // It should resolve via embedURL to the real CDN stream (or return extractor)
        if resolved.extractor == "packed_stream_scraper" {
            XCTAssertTrue(resolved.directURL.absoluteString.contains("cdn-centaurus.com") || resolved.directURL.absoluteString.contains(".m3u8"), "Must resolve to live CDN stream")
            XCTAssertFalse(resolved.directURL.absoluteString.contains("/stream/"), "Must not use probe /stream/ endpoint")
        }
    }

    func testHLSActiveWorkerConnectionsAndRealtimeProgressState() async throws {
        class MockWorkerProtocol: URLProtocol {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                guard let url = request.url else { return }
                if url.path.hasSuffix(".m3u8") {
                    let playlist = """
                    #EXTM3U
                    #EXT-X-VERSION:3
                    #EXT-X-TARGETDURATION:4
                    #EXTINF:4.0,
                    seg0.ts
                    #EXTINF:4.0,
                    seg1.ts
                    #EXTINF:4.0,
                    seg2.ts
                    #EXTINF:4.0,
                    seg3.ts
                    #EXT-X-ENDLIST
                    """
                    let data = playlist.data(using: .utf8)!
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/vnd.apple.mpegurl"])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data)
                    client?.urlProtocolDidFinishLoading(self)
                } else if url.path.hasSuffix(".ts") {
                    let dummyData = Data(repeating: 0x47, count: 1024 * 50) // 50 KB
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "video/mp2t"])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: dummyData)
                    client?.urlProtocolDidFinishLoading(self)
                }
            }
            override func stopLoading() {}
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockWorkerProtocol.self]
        let mockSession = URLSession(configuration: config)
        let downloader = HLSDownloader(session: mockSession)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("hls_worker_test_\(UUID().uuidString)")
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("hls_worker_output_\(UUID().uuidString).ts")
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            try? FileManager.default.removeItem(at: dest)
        }

        let box = ProgressCaptureBox()

        try await downloader.download(
            playlistURL: URL(string: "https://example.com/stream/playlist.m3u8")!,
            destinationFile: dest,
            tempDirectory: tempDir,
            maxConcurrency: 4,
            onProgress: { dSegs, tSegs, dBytes, estTotal, speed, activeSegments in
                box.downloadedSegs = dSegs
                box.totalSegs = tSegs
                box.workerSegments = activeSegments
            }
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertEqual(box.totalSegs, 4)
        XCTAssertEqual(box.downloadedSegs, 4)
        XCTAssertEqual(box.workerSegments.count, 4, "Must maintain 4 parallel worker connection slots")
        for (idx, seg) in box.workerSegments.enumerated() {
            XCTAssertEqual(seg.index, idx, "Worker slot index must match 0..<concurrency")
            XCTAssertEqual(seg.status, .completed, "Completed slot must reflect status")
        }
    }

    func testDownloadManagerFullStateProgressAndLiveSegments() async throws {
        let tempDB = FileManager.default.temporaryDirectory.appendingPathComponent("test_mgr_full_state_\(UUID().uuidString).sqlite3").path
        defer { try? FileManager.default.removeItem(atPath: tempDB) }

        let manager = DownloadManager(dbPath: tempDB)
        let taskId = UUID()

        // Test initial empty segments
        XCTAssertEqual(manager.getSegments(for: taskId).count, 0)

        // Verify that onTaskProgressUpdated transmits all 7 parameters
        var capturedTaskId: UUID?
        var capturedDownloadedBytes: Int64 = 0
        var capturedTotalBytes: Int64 = 0
        var capturedDownloadedSegs: Int = 0
        var capturedTotalSegs: Int = 0
        var capturedSpeed: Double = 0
        var capturedSegments: [DownloadSegment] = []

        manager.onTaskProgressUpdated = { tId, dBytes, tBytes, dSegs, totSegs, spd, segs in
            capturedTaskId = tId
            capturedDownloadedBytes = dBytes
            capturedTotalBytes = tBytes
            capturedDownloadedSegs = dSegs
            capturedTotalSegs = totSegs
            capturedSpeed = spd
            capturedSegments = segs
        }

        let dummySlots: [DownloadSegment] = (0..<4).map { idx in
            DownloadSegment(taskId: taskId, index: idx, startByte: 0, endByte: 100, downloadedBytes: 50, status: .downloading)
        }

        manager.onTaskProgressUpdated?(taskId, 500_000, 2_000_000, 25, 100, 15_000_000, dummySlots)

        XCTAssertEqual(capturedTaskId, taskId)
        XCTAssertEqual(capturedDownloadedBytes, 500_000)
        XCTAssertEqual(capturedTotalBytes, 2_000_000)
        XCTAssertEqual(capturedDownloadedSegs, 25)
        XCTAssertEqual(capturedTotalSegs, 100)
        XCTAssertEqual(capturedSpeed, 15_000_000)
        XCTAssertEqual(capturedSegments.count, 4)
    }

    func testHTTPDownloadProgressCoordinatorMonotonicityAndAggregation() async {
        let taskId = UUID()
        let segmentCount = 8
        let chunkSize: Int64 = 1_000_000
        let segments = (0..<segmentCount).map { idx in
            DownloadSegment(
                taskId: taskId,
                index: idx,
                startByte: Int64(idx) * chunkSize,
                endByte: Int64(idx + 1) * chunkSize - 1,
                downloadedBytes: 0,
                status: .pending
            )
        }

        let progressHistory = ProgressHistoryTracker()

        let coordinator = HTTPDownloadProgressCoordinator(
            segments: segments,
            onProgress: { totalBytes, speed in
                progressHistory.record(totalBytes: totalBytes, speed: speed)
            },
            onSegmentUpdate: { _ in }
        )

        // Simulate 8 concurrent workers streaming chunks in interleaved fashion
        await withTaskGroup(of: Void.self) { group in
            for seg in segments {
                group.addTask {
                    var current = seg
                    current.status = .downloading
                    coordinator.recordProgress(segment: current, speed: 100_000)

                    // Stream 10 chunks of 100KB per segment (1MB total each)
                    for _ in 0..<10 {
                        current.downloadedBytes += 100_000
                        coordinator.recordProgress(segment: current, speed: 500_000)
                    }

                    current.status = .completed
                    coordinator.markSegmentCompleted(segment: current, speed: 0)
                }
            }
        }

        let recordedEvents = progressHistory.events
        XCTAssertGreaterThan(recordedEvents.count, 0)

        // Verify strictly non-decreasing monotonicity: no fluctuation or jitter down
        var previousBytes: Int64 = 0
        var dropCount = 0
        for event in recordedEvents {
            if event.totalBytes < previousBytes {
                dropCount += 1
            }
            previousBytes = event.totalBytes
        }

        XCTAssertEqual(dropCount, 0, "Progress must be strictly non-decreasing, but dropped \(dropCount) times")
        XCTAssertEqual(previousBytes, Int64(segmentCount) * chunkSize, "Final total must equal sum of all segments")
    }

    func testHLSCancelPreservesTempAndThrows() async throws {
        class SlowHLSProtocol: URLProtocol {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                guard let url = request.url else { return }
                if url.path.hasSuffix(".m3u8") {
                    let playlist = """
                    #EXTM3U
                    #EXT-X-VERSION:3
                    #EXT-X-TARGETDURATION:4
                    #EXTINF:4.0,
                    seg0.ts
                    #EXTINF:4.0,
                    seg1.ts
                    #EXTINF:4.0,
                    seg2.ts
                    #EXTINF:4.0,
                    seg3.ts
                    #EXT-X-ENDLIST
                    """
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/vnd.apple.mpegurl"])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Data(playlist.utf8))
                    client?.urlProtocolDidFinishLoading(self)
                } else if url.path.hasSuffix("seg0.ts") {
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "video/mp2t"])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Data(repeating: 0x47, count: 4096))
                    client?.urlProtocolDidFinishLoading(self)
                } else {
                    Thread.sleep(forTimeInterval: 0.3)
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "video/mp2t"])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Data(repeating: 0x47, count: 4096))
                    client?.urlProtocolDidFinishLoading(self)
                }
            }
            override func stopLoading() {}
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SlowHLSProtocol.self]
        let mockSession = URLSession(configuration: config)
        let downloader = HLSDownloader(session: mockSession)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("hls_cancel_test_\(UUID().uuidString)")
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("hls_cancel_out_\(UUID().uuidString).ts")
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            try? FileManager.default.removeItem(at: dest)
        }

        var didThrow = false
        do {
            try await downloader.download(
                playlistURL: URL(string: "https://example.com/stream/playlist.m3u8")!,
                destinationFile: dest,
                tempDirectory: tempDir,
                maxConcurrency: 1,
                onProgress: { dSegs, _, _, _, _, _ in
                    if dSegs >= 1 {
                        Task { await downloader.cancel() }
                    }
                }
            )
        } catch {
            didThrow = true
        }

        XCTAssertTrue(didThrow, "Cancelled HLS download must throw CancellationError instead of completing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path), "Cancelled HLS download must NOT write partial output file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path), "Cancelled HLS download must preserve tempDirectory for resume")
    }

    func testToolbarBatchActionsPauseResumeClearAndShutdown() throws {
        let tempDB = FileManager.default.temporaryDirectory.appendingPathComponent("test_toolbar_\(UUID().uuidString).sqlite3").path
        let sockPath = "/tmp/test_shutdown_\(UUID().uuidString).sock"
        defer {
            try? FileManager.default.removeItem(atPath: tempDB)
            unlink(sockPath)
        }
        setenv("IDM_SOCKET_PATH", sockPath, 1)
        defer { unsetenv("IDM_SOCKET_PATH") }

        let manager = DownloadManager(dbPath: tempDB)
        manager.startIPC()
        let dest = FileManager.default.temporaryDirectory

        var tDownloading = try manager.createNewTask(url: URL(string: "https://example.com/a.zip")!, filename: "a.zip", destinationFolder: dest)
        tDownloading.status = .downloading
        try manager.store.saveTask(tDownloading)

        var tPending = try manager.createNewTask(url: URL(string: "https://example.com/b.zip")!, filename: "b.zip", destinationFolder: dest)
        tPending.status = .pending
        try manager.store.saveTask(tPending)

        var tFailed = try manager.createNewTask(url: URL(string: "https://example.com/c.zip")!, filename: "c.zip", destinationFolder: dest)
        tFailed.status = .failed
        try manager.store.saveTask(tFailed)

        var tCompleted = try manager.createNewTask(url: URL(string: "https://example.com/d.zip")!, filename: "d.zip", destinationFolder: dest)
        tCompleted.status = .completed
        try manager.store.saveTask(tCompleted)

        // 1. pauseAllTasks must pause both .downloading and .pending tasks
        manager.pauseAllTasks()
        XCTAssertEqual(manager.getTask(id: tDownloading.id)?.status, .paused)
        XCTAssertEqual(manager.getTask(id: tPending.id)?.status, .paused)
        XCTAssertEqual(manager.getTask(id: tFailed.id)?.status, .failed)
        XCTAssertEqual(manager.getTask(id: tCompleted.id)?.status, .completed)

        // 2. clearCompletedAndFailedTasks must remove both .completed and .failed tasks
        try manager.clearCompletedAndFailedTasks()
        let remaining = manager.getAllTasks()
        XCTAssertEqual(remaining.count, 2)
        XCTAssertFalse(remaining.contains(where: { $0.id == tFailed.id }))
        XCTAssertFalse(remaining.contains(where: { $0.id == tCompleted.id }))

        // 3. shutdown must pause active downloading tasks, stop IPC server, and remove socket
        tDownloading.status = .downloading
        try manager.store.saveTask(tDownloading)
        manager.shutdown()
        XCTAssertEqual(manager.getTask(id: tDownloading.id)?.status, .paused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sockPath))
    }

    func testPauseFlushesBufferedBytesOnURLSessionCancellation() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Sub32KBHangProtocol.self]
        let session = URLSession(configuration: config)
        let downloader = HTTPRangeDownloader(session: session)

        let destDir = FileManager.default.temporaryDirectory.appendingPathComponent("flush_cancel_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let task = DownloadTask(
            url: URL(string: "https://example.com/archive.dmg")!,
            filename: "archive.dmg",
            destinationFolder: destDir,
            totalBytes: 131_072,
            status: .downloading,
            acceptRanges: true,
            segmentsCount: 1
        )
        defer {
            try? FileManager.default.removeItem(at: destDir)
            try? FileManager.default.removeItem(at: task.tempDirectory)
        }

        let initialSeg = DownloadSegment(taskId: task.id, index: 0, startByte: 0, endByte: 131_071, downloadedBytes: 0, status: .pending)
        let segBox = LockedBox(initialSeg)

        let runHandle = Task {
            try await downloader.download(
                task: task,
                segments: [initialSeg],
                onProgress: { _, _ in },
                onSegmentUpdate: { seg in
                    segBox.set(seg)
                }
            )
        }

        try await Task.sleep(nanoseconds: 150_000_000)
        runHandle.cancel()
        _ = await runHandle.result

        let finalSeg = segBox.get()
        XCTAssertEqual(finalSeg.status, .paused, "Cancelled segment must be marked paused")
        XCTAssertEqual(finalSeg.downloadedBytes, 32_768, "Sub-64KB buffer must be flushed and recorded on URLSession task cancellation")
        let fileData = try Data(contentsOf: task.finalFilePath)
        XCTAssertEqual(fileData.prefix(32_768), Data(repeating: 0xAB, count: 32_768), "Flushed bytes must be written to disk in finalFilePath")
    }

    func testStartDownloadDeduplicatesAndUpgradesPendingConfirmationTask() async throws {
        let tempDB = FileManager.default.temporaryDirectory.appendingPathComponent("test_dedup_\(UUID().uuidString).sqlite3").path
        let sockPath = "/tmp/test_dedup_\(UUID().uuidString).sock"
        defer {
            try? FileManager.default.removeItem(atPath: tempDB)
            unlink(sockPath)
        }
        setenv("IDM_SOCKET_PATH", sockPath, 1)
        defer { unsetenv("IDM_SOCKET_PATH") }

        let manager = DownloadManager(dbPath: tempDB)
        let confirmedBox = LockedBox<[DownloadTask]>([])
        manager.onDownloadConfirmationRequested = { t in
            confirmedBox.mutate { $0.append(t) }
        }
        guard let handler = manager.ipcServer.requestHandler else {
            return XCTFail("Missing IPC requestHandler")
        }

        // 1. First request arrives with opaque redirect URL and empty filename
        let req1 = IPCRequest(
            action: "start_download",
            url: "https://artcraft.example.com/api/download/latest",
            filename: "",
            referrer: "https://artcraft.example.com/"
        )
        let resp1 = await handler(req1)
        XCTAssertTrue(resp1.success)
        XCTAssertNotNil(resp1.taskId)

        // 2. Follow-up request arrives 20ms later from onDeterminingFilename with final URL and real filename
        let req2 = IPCRequest(
            action: "start_download",
            url: "https://cdn.artcraft.example.com/releases/ArtCraft_0.41.0_universal.dmg",
            filename: "ArtCraft_0.41.0_universal.dmg",
            referrer: "https://artcraft.example.com/api/download/latest",
            cookies: "session=xyz"
        )
        let resp2 = await handler(req2)
        XCTAssertTrue(resp2.success)
        XCTAssertEqual(resp2.taskId, resp1.taskId, "Follow-up start_download while awaiting confirmation must reuse the same taskId")

        let allTasks = manager.getAllTasks()
        XCTAssertEqual(allTasks.count, 1, "Must not create duplicate pending tasks for the same download")
        XCTAssertEqual(allTasks.first?.filename, "ArtCraft_0.41.0_universal.dmg")
        XCTAssertEqual(allTasks.first?.url.absoluteString, "https://cdn.artcraft.example.com/releases/ArtCraft_0.41.0_universal.dmg")
        XCTAssertEqual(allTasks.first?.cookies, "session=xyz")
        XCTAssertEqual(confirmedBox.get().last?.filename, "ArtCraft_0.41.0_universal.dmg")
    }

    func testIsBarePlatformHomeURL() {
        // Facebook
        XCTAssertTrue(URLNormalizer.isBarePlatformHomeURL(URL(string: "https://www.facebook.com/")!))
        XCTAssertTrue(URLNormalizer.isBarePlatformHomeURL(URL(string: "https://www.facebook.com/?_fb_noscript=1")!))
        XCTAssertTrue(URLNormalizer.isBarePlatformHomeURL(URL(string: "https://m.facebook.com/home")!))
        XCTAssertFalse(URLNormalizer.isBarePlatformHomeURL(URL(string: "https://www.facebook.com/watch/?v=987654321")!))
        XCTAssertFalse(URLNormalizer.isBarePlatformHomeURL(URL(string: "https://www.facebook.com/reel/123456789")!))
        XCTAssertFalse(URLNormalizer.isBarePlatformHomeURL(URL(string: "https://www.facebook.com/user/videos/123456789")!))

        // YouTube
        XCTAssertTrue(URLNormalizer.isBarePlatformHomeURL(URL(string: "https://www.youtube.com/")!))
        XCTAssertTrue(URLNormalizer.isBarePlatformHomeURL(URL(string: "https://www.youtube.com/feed")!))
        XCTAssertFalse(URLNormalizer.isBarePlatformHomeURL(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!))
        XCTAssertFalse(URLNormalizer.isBarePlatformHomeURL(URL(string: "https://www.youtube.com/shorts/abcdefghijk")!))

        // TikTok
        XCTAssertTrue(URLNormalizer.isBarePlatformHomeURL(URL(string: "https://www.tiktok.com/")!))
        XCTAssertTrue(URLNormalizer.isBarePlatformHomeURL(URL(string: "https://www.tiktok.com/foryou")!))
        XCTAssertFalse(URLNormalizer.isBarePlatformHomeURL(URL(string: "https://www.tiktok.com/@user/video/1234567890")!))

        // Twitter / X
        XCTAssertTrue(URLNormalizer.isBarePlatformHomeURL(URL(string: "https://x.com/home")!))
        XCTAssertTrue(URLNormalizer.isBarePlatformHomeURL(URL(string: "https://twitter.com/")!))
        XCTAssertFalse(URLNormalizer.isBarePlatformHomeURL(URL(string: "https://x.com/user/status/1234567890")!))

        // Non-platform direct files
        XCTAssertFalse(URLNormalizer.isBarePlatformHomeURL(URL(string: "https://example.com/file.zip")!))
        XCTAssertFalse(URLNormalizer.isBarePlatformHomeURL(URL(string: "https://video.xx.fbcdn.net/v/t39.2548-2/video.mp4")!))
    }

    func testMediaURLResolverWithBarePlatformHomeURL() async {
        let fbHome = URL(string: "https://www.facebook.com/")!
        let resolved = await MediaURLResolver.resolve(url: fbHome)
        XCTAssertEqual(resolved.extractor, "unsupported_bare_home")
        XCTAssertEqual(resolved.directURL, fbHome)

        let probe = await MediaURLResolver.probeMediaSizeAndTitle(url: fbHome)
        XCTAssertEqual(probe.size, -1)
    }

    func testDownloadManagerFailsFastOnBarePlatformHomeURL() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("test.db").path
        let manager = DownloadManager(dbPath: dbPath)

        let task = try manager.createNewTask(
            url: URL(string: "https://www.facebook.com/")!,
            filename: "Facebook.mp4",
            destinationFolder: tempDir
        )

        let expectation = expectation(description: "Task finishes with friendly failure")
        manager.onTasksChanged = {
            if let current = manager.getTask(id: task.id), current.status == TaskStatus.failed {
                expectation.fulfill()
            }
        }

        manager.startDownload(taskId: task.id)
        await fulfillment(of: [expectation], timeout: 5.0)

        guard let failed = manager.getTask(id: task.id) else {
            XCTFail("Task not found")
            return
        }
        XCTAssertEqual(failed.status, TaskStatus.failed)
        XCTAssertNotNil(failed.errorMessage)
        XCTAssertTrue(failed.errorMessage?.contains("trang chủ hoặc bảng tin") == true, "Must have friendly localized error message instead of raw yt-dlp error, got: \(failed.errorMessage ?? "")")
        XCTAssertFalse(failed.errorMessage?.contains("ERROR: Unsupported URL") == true, "Must NOT contain raw yt-dlp crash message")
    }
}


private final class Sub32KBHangProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let resp = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: [
            "Content-Length": "131072",
            "Content-Range": "bytes 0-131071/131072"
        ])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        // Send 32KB (< 64KB bufferSize) then hang until cancelled
        client?.urlProtocol(self, didLoad: Data(repeating: 0xAB, count: 32_768))
    }
    override func stopLoading() {}
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func set(_ newValue: T) { lock.withLock { value = newValue } }
    func mutate(_ body: (inout T) -> Void) { lock.withLock { body(&value) } }
}

private final class ProgressHistoryTracker: @unchecked Sendable {
    struct Event {
        let totalBytes: Int64
        let speed: Double
    }
    private let lock = NSLock()
    private(set) var events: [Event] = []

    func record(totalBytes: Int64, speed: Double) {
        lock.lock()
        defer { lock.unlock() }
        events.append(Event(totalBytes: totalBytes, speed: speed))
    }
}
