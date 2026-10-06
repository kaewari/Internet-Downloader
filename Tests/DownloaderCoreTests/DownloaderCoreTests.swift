import XCTest
@testable import DownloaderCore

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
}
