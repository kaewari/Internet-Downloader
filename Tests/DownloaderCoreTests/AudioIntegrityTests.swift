import XCTest
import SQLite3
@testable import DownloaderCore

/// Hồi quy cho lỗi "video tải về không có tiếng":
/// * `MediaIntegrity` phải phân biệt được file có/không có luồng audio.
/// * Master playlist HLS phải ghép đúng `EXT-X-MEDIA` theo `AUDIO="group"`.
/// * yt-dlp để lại file rời (`.fNNN.`) phải được ghép lại, không chọn bừa.
/// * Bước hoàn tất phải fail rõ ràng khi nguồn có tiếng mà file ra không có.
/// * Fixture server cục bộ (HLS tách audio, HLS audio 404, mp4 video-only)
///   phải đi qua đúng pipeline của app.
final class AudioIntegrityTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioIntegrityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - Helpers

    private var ffmpegPath: String? { MediaURLResolver.findFfmpegBinary() }

    /// Tạo file media thật bằng ffmpeg (1 giây, 160x120) có/không có audio.
    private func makeMedia(name: String, withAudio: Bool) throws -> URL {
        guard let ffmpeg = ffmpegPath else { throw XCTSkip("ffmpeg không khả dụng") }
        let output = tempDir.appendingPathComponent(name)
        var args = [
            "-y", "-nostdin",
            "-f", "lavfi", "-i", "testsrc=size=160x120:rate=10:duration=1"
        ]
        if withAudio {
            args += ["-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-c:a", "aac", "-b:a", "64k", "-shortest"]
        }
        args += ["-c:v", "libx264", "-pix_fmt", "yuv420p", output.path]

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0, "ffmpeg tạo fixture thất bại")
        return output
    }

    private func makeAudioOnly(name: String) throws -> URL {
        guard let ffmpeg = ffmpegPath else { throw XCTSkip("ffmpeg không khả dụng") }
        let output = tempDir.appendingPathComponent(name)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = [
            "-y", "-nostdin",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
            "-c:a", "aac", "-b:a", "64k",
            output.path
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0, "ffmpeg tạo audio fixture thất bại")
        return output
    }

    private func makeManager() -> DownloadManager {
        DownloadManager(dbPath: tempDir.appendingPathComponent("test-\(UUID().uuidString).sqlite").path)
    }

    // MARK: - MediaIntegrity

    func testMediaIntegrityDetectsVideoAndAudio() throws {
        let file = try makeMedia(name: "with-audio.mp4", withAudio: true)
        let report = MediaIntegrity.report(of: file)
        XCTAssertNotNil(report)
        XCTAssertEqual(report?.hasVideo, true)
        XCTAssertEqual(report?.hasAudio, true)
        XCTAssertEqual(MediaIntegrity.audioVerdict(of: file), .hasAudio)
    }

    func testMediaIntegrityDetectsVideoOnly() throws {
        let file = try makeMedia(name: "video-only.mp4", withAudio: false)
        XCTAssertEqual(MediaIntegrity.report(of: file)?.hasVideo, true)
        XCTAssertEqual(MediaIntegrity.report(of: file)?.hasAudio, false)
        XCTAssertEqual(MediaIntegrity.audioVerdict(of: file), .noAudio)
    }

    func testMediaIntegrityUnverifiableForMissingFile() {
        let missing = tempDir.appendingPathComponent("does-not-exist.mp4")
        XCTAssertNil(MediaIntegrity.report(of: missing))
        XCTAssertEqual(MediaIntegrity.audioVerdict(of: missing), .unverifiable)
    }

    func testMediaIntegrityKnowsVideoContainers() {
        XCTAssertTrue(MediaIntegrity.isLikelyVideoContainer(URL(fileURLWithPath: "/tmp/a.mp4")))
        XCTAssertTrue(MediaIntegrity.isLikelyVideoContainer(URL(fileURLWithPath: "/tmp/a.mkv")))
        XCTAssertTrue(MediaIntegrity.isLikelyVideoContainer(URL(fileURLWithPath: "/tmp/a.m3u8")))
        XCTAssertFalse(MediaIntegrity.isLikelyVideoContainer(URL(fileURLWithPath: "/tmp/a.zip")))
        XCTAssertFalse(MediaIntegrity.isLikelyVideoContainer(URL(fileURLWithPath: "/tmp/a.mp3")))
    }

    // MARK: - HLS master playlist

    func testHLSMasterPlaylistChoosesAudioGroupOfVariant() {
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="en",DEFAULT=YES,AUTOSELECT=YES,URI="en.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="ac3",NAME="fr",URI="fr.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=900000,AUDIO="ac3"
        low.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,AUDIO="aac"
        high.m3u8
        """
        let base = URL(string: "https://cdn.example.com/hls/master.m3u8")!
        let parsed = HLSDownloader.parseMasterPlaylist(content: master, baseURL: base)

        XCTAssertEqual(parsed.variants.count, 2)
        XCTAssertEqual(parsed.audioRenditions.count, 2)
        let best = parsed.bestVariant
        XCTAssertEqual(best?.uri.absoluteString, "https://cdn.example.com/hls/high.m3u8")
        // Variant chất lượng cao dùng group "aac" → phải chọn en.m3u8,
        // KHÔNG phải rendition đầu tiên trong file.
        XCTAssertEqual(parsed.audioRendition(for: best!)?.uri.absoluteString,
                       "https://cdn.example.com/hls/en.m3u8")
        let low = parsed.variants.first { $0.uri.absoluteString.hasSuffix("low.m3u8") }
        XCTAssertEqual(parsed.audioRendition(for: low!)?.uri.absoluteString,
                       "https://cdn.example.com/hls/fr.m3u8")
    }

    func testHLSMasterPlaylistWithoutAudioGroupHasNoSeparateAudio() {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1200000
        muxed.m3u8
        """
        let base = URL(string: "https://cdn.example.com/master.m3u8")!
        let parsed = HLSDownloader.parseMasterPlaylist(content: master, baseURL: base)
        XCTAssertEqual(parsed.variants.count, 1)
        XCTAssertNil(parsed.bestVariant.flatMap { parsed.audioRendition(for: $0) })
    }

    func testHLSMasterPlaylistHandlesAbsentAudioGroupRendition() {
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="other",NAME="x",URI="x.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=800000,AUDIO="missing-group"
        v.m3u8
        """
        let base = URL(string: "https://cdn.example.com/master.m3u8")!
        let parsed = HLSDownloader.parseMasterPlaylist(content: master, baseURL: base)
        XCTAssertNil(parsed.bestVariant.flatMap { parsed.audioRendition(for: $0) })
    }

    // MARK: - Muxer container choice

    func testMediaMuxerPreferredContainer() {
        XCTAssertEqual(MediaMuxer.preferredContainer(videoStreamExtension: "webm"), "webm")
        XCTAssertEqual(MediaMuxer.preferredContainer(videoStreamExtension: "mkv"), "mkv")
        XCTAssertEqual(MediaMuxer.preferredContainer(videoStreamExtension: "mp4"), "mp4")
        XCTAssertEqual(MediaMuxer.preferredContainer(videoStreamExtension: "mov"), "mp4")
        XCTAssertEqual(MediaMuxer.preferredContainer(videoStreamExtension: nil), "mp4")
    }

    // MARK: - yt-dlp split output

    func testRecoverYtDlpSplitOutputMergesVideoAndAudio() throws {
        let video = try makeMedia(name: "video-part.mp4", withAudio: false)
        let audio = try makeAudioOnly(name: "audio-part.m4a")
        let folder = tempDir.appendingPathComponent("split")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // yt-dlp đặt tên dạng `<base>.f<id>.<ext>` khi không merge được.
        let partVideo = folder.appendingPathComponent("movie.f137.mp4")
        let partAudio = folder.appendingPathComponent("movie.f251.m4a")
        try FileManager.default.moveItem(at: video, to: partVideo)
        try FileManager.default.moveItem(at: audio, to: partAudio)

        let manager = makeManager()
        let task = try manager.createNewTask(url: URL(string: "https://example.com/movie")!, destinationFolder: folder)
        let target = folder.appendingPathComponent("movie.mp4")

        let recovered = try manager.recoverYtDlpSplitOutput(
            targetFile: target,
            folder: folder,
            task: task,
            declaredAudio: true
        )
        XCTAssertNotNil(recovered)
        let report = MediaIntegrity.report(of: recovered!.url)
        XCTAssertEqual(report?.hasVideo, true)
        XCTAssertEqual(report?.hasAudio, true, "File rời phải được ghép thành video+audio")
        XCTAssertEqual(recovered?.repaired, true)
        manager.shutdown()
    }

    // MARK: - Completion gate

    func testFinalizeFailsWhenDeclaredAudioIsMissing() async throws {
        let videoOnly = try makeMedia(name: "silent.mp4", withAudio: false)
        let manager = makeManager()
        let task = try manager.createNewTask(url: URL(string: "https://example.com/video")!, destinationFolder: tempDir)

        let finalized = await manager.finalizeMediaTask(
            task,
            fileURL: videoOnly,
            declaredAudio: true,
            allowRepair: false
        )
        XCTAssertEqual(finalized.status, .failed)
        XCTAssertEqual(finalized.audioState, .missingInSource)
        XCTAssertTrue(finalized.errorMessage?.contains("tiếng") == true)
        manager.shutdown()
    }

    func testFinalizeKeepsCompletedWhenSourceHasNoAudio() async throws {
        let videoOnly = try makeMedia(name: "silent-source.mp4", withAudio: false)
        let manager = makeManager()
        var task = try manager.createNewTask(url: URL(string: "https://example.com/silent")!, destinationFolder: tempDir)
        task.status = .downloading

        let finalized = await manager.finalizeMediaTask(
            task,
            fileURL: videoOnly,
            declaredAudio: nil,
            allowRepair: false
        )
        // Nguồn không khai báo audio → không fail, nhưng phải ghi nhận trạng thái.
        XCTAssertNotEqual(finalized.status, .failed)
        XCTAssertEqual(finalized.audioState, .missingInSource)
        manager.shutdown()
    }

    func testFinalizeVerifiesAudioWhenPresent() async throws {
        let withAudio = try makeMedia(name: "good.mp4", withAudio: true)
        let manager = makeManager()
        let task = try manager.createNewTask(url: URL(string: "https://example.com/good")!, destinationFolder: tempDir)

        let finalized = await manager.finalizeMediaTask(
            task,
            fileURL: withAudio,
            declaredAudio: true,
            allowRepair: false
        )
        XCTAssertEqual(finalized.audioState, .verified)
        XCTAssertNotEqual(finalized.status, .failed)
        manager.shutdown()
    }

    // MARK: - Storage

    func testAudioStateRoundTripsThroughSQLite() throws {
        let store = try SQLiteStore(path: tempDir.appendingPathComponent("state.sqlite").path)
        var task = DownloadTask(url: URL(string: "https://example.com/a.mp4")!, filename: "a.mp4", destinationFolder: tempDir)
        task.audioState = .repaired
        try store.saveTask(task)

        let loaded = try store.getTask(id: task.id)
        XCTAssertEqual(loaded?.audioState, .repaired)

        var updated = task
        updated.audioState = .missingInSource
        try store.saveTask(updated)
        XCTAssertEqual(try store.getTask(id: task.id)?.audioState, .missingInSource)
    }

    func testAudioStateMigrationOnLegacyDatabase() throws {
        let path = tempDir.appendingPathComponent("legacy.sqlite").path
        // Tạo DB "cũ" không có cột audio_state rồi mở lại bằng SQLiteStore hiện tại.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let legacySQL = """
        CREATE TABLE tasks (
            id TEXT PRIMARY KEY, url TEXT NOT NULL, filename TEXT NOT NULL,
            destination_folder TEXT NOT NULL, total_bytes INTEGER NOT NULL,
            downloaded_bytes INTEGER NOT NULL, status TEXT NOT NULL, speed REAL NOT NULL,
            etag TEXT, last_modified TEXT, accept_ranges INTEGER NOT NULL,
            segments_count INTEGER NOT NULL, error_message TEXT,
            created_at REAL NOT NULL, updated_at REAL NOT NULL, referrer TEXT,
            user_agent TEXT, cookies TEXT
        );
        """
        XCTAssertEqual(sqlite3_exec(db, legacySQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let store = try SQLiteStore(path: path)
        var task = DownloadTask(url: URL(string: "https://example.com/b.mp4")!, filename: "b.mp4", destinationFolder: tempDir)
        task.audioState = .verified
        try store.saveTask(task)
        XCTAssertEqual(try store.getTask(id: task.id)?.audioState, .verified)
    }
}

// MARK: - Fixture server integration

/// Chạy đúng pipeline của app với HTTP fixture cục bộ (không cần mạng).
final class AudioPipelineFixtureTests: XCTestCase {

    private var tempDir: URL!
    private var server: Process?
    private var serverPort: Int?

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioFixtureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try startFixtureServer()
    }

    override func tearDownWithError() throws {
        server?.terminate()
        server?.waitUntilExit()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func fixtureScript() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/Fixtures/media_server.py")
    }

    private func startFixtureServer() throws {
        let script = fixtureScript()
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw XCTSkip("Fixture server chưa có: \(script.path)")
        }
        guard MediaURLResolver.findFfmpegBinary() != nil else {
            throw XCTSkip("ffmpeg không khả dụng để tạo fixture")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", script.path, "--port", "0"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        server = proc

        // Server in `{"port": <n>}` ra stdout rồi flush.
        let handle = pipe.fileHandleForReading
        let deadline = Date().addingTimeInterval(30)
        var buffer = Data()
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            if buffer.contains(0x0A) { break }
        }
        guard let line = String(data: buffer, encoding: .utf8)?
            .split(separator: "\n").first.map(String.init),
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let port = object["port"] as? Int else {
            proc.terminate()
            throw XCTSkip("Không đọc được port của fixture server")
        }
        serverPort = port
    }

    private func serverURL(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(serverPort!)/\(path)")!
    }

    private func makeManager() -> DownloadManager {
        DownloadManager(dbPath: tempDir.appendingPathComponent("fixture-\(UUID().uuidString).sqlite").path)
    }

    private func waitForTask(_ manager: DownloadManager, id: UUID, timeout: TimeInterval = 120) async -> DownloadTask? {
        let waiter = FixtureWaiter()
        manager.onDownloadCompleted = { waiter.complete($0) }
        manager.onDownloadFailed = { waiter.complete($0) }
        manager.startDownload(taskId: id)
        return await waiter.wait(timeout: timeout)
    }

    func testFixtureHLSWithSeparateAudioProducesVideoAndAudio() async throws {
        let manager = makeManager()
        defer { manager.shutdown() }
        let task = try manager.createNewTask(url: serverURL("hls/master.m3u8"), destinationFolder: tempDir)
        guard let finished = await waitForTask(manager, id: task.id) else {
            XCTFail("Timeout tải HLS fixture")
            return
        }
        XCTAssertEqual(finished.status, .completed, finished.errorMessage ?? "")
        let report = MediaIntegrity.report(of: finished.finalFilePath)
        XCTAssertEqual(report?.hasVideo, true)
        XCTAssertEqual(report?.hasAudio, true, "HLS tách audio phải được ghép thành video+audio")
        XCTAssertEqual(finished.audioState, .verified)
    }

    func testFixtureBrokenHLSAudioFailsInsteadOfSilentVideo() async throws {
        let manager = makeManager()
        defer { manager.shutdown() }
        let task = try manager.createNewTask(url: serverURL("hls-broken/master.m3u8"), destinationFolder: tempDir)
        guard let finished = await waitForTask(manager, id: task.id) else {
            XCTFail("Timeout tải HLS hỏng audio")
            return
        }
        XCTAssertEqual(finished.status, .failed, "Không được publish video-only khi nguồn khai báo có audio")
        let fileExists = FileManager.default.fileExists(atPath: finished.finalFilePath.path)
        if fileExists {
            XCTAssertEqual(MediaIntegrity.report(of: finished.finalFilePath)?.hasAudio, true,
                           "Nếu có file thì file đó không được là video câm")
        }
    }

    func testFixtureDirectVideoOnlyIsFlaggedWithoutAudio() async throws {
        let manager = makeManager()
        defer { manager.shutdown() }
        let task = try manager.createNewTask(url: serverURL("direct/video-only.mp4"), destinationFolder: tempDir)
        guard let finished = await waitForTask(manager, id: task.id) else {
            XCTFail("Timeout tải mp4 video-only")
            return
        }
        XCTAssertEqual(finished.status, .completed, finished.errorMessage ?? "")
        XCTAssertEqual(MediaIntegrity.report(of: finished.finalFilePath)?.hasVideo, true)
        XCTAssertEqual(MediaIntegrity.report(of: finished.finalFilePath)?.hasAudio, false)
        // Link trực tiếp không khai báo audio → hoàn tất kèm cảnh báo, không fail oan.
        XCTAssertEqual(finished.audioState, .missingInSource)
    }
}

private final class FixtureWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DownloadTask?, Never>?
    private var finishedTask: DownloadTask?

    func complete(_ task: DownloadTask) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: task)
        } else {
            finishedTask = task
            lock.unlock()
        }
    }

    func wait(timeout: TimeInterval) async -> DownloadTask? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let task = finishedTask {
                finishedTask = nil
                lock.unlock()
                continuation.resume(returning: task)
                return
            }
            self.continuation = continuation
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                if let continuation = self.continuation {
                    self.continuation = nil
                    self.lock.unlock()
                    continuation.resume(returning: nil)
                } else {
                    self.lock.unlock()
                }
            }
        }
    }
}
