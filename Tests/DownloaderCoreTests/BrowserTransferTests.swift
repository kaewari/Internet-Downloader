import XCTest
@testable import DownloaderCore

final class BrowserTransferTests: XCTestCase {
    func testBrowserSourcesNeverBecomeHTTPURLs() {
        XCTAssertNil(URLNormalizer.normalize("blob:https://web.telegram.org/123"))
        XCTAssertNil(URLNormalizer.normalize("https://web.telegram.org/k/stream/%7Bredacted%7D"))
        XCTAssertNil(URLNormalizer.normalize("https://web.telegram.org/k/#123"))
        XCTAssertNotNil(URLNormalizer.normalize("https://example.com/video.mp4"))
        XCTAssertNotNil(URLNormalizer.normalize("https://t.me/example/1"))
    }
}

import CryptoKit

final class BrowserProtocolTests: XCTestCase {
    private func environment() throws -> (URL, SQLiteStore, DownloadSlots, BrowserTransfers) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try SQLiteStore(path: dir.appendingPathComponent("test.sqlite3").path)
        let slots = DownloadSlots()
        return (dir, store, slots, BrowserTransfers(store: store, slots: slots, destination: dir, notify: {}))
    }
    private func create(_ engine: BrowserTransfers, name: String = "sample.bin", kind: String = "file") async throws -> (String, String, String) {
        let session = UUID().uuidString
        let response = await engine.command(IPCRequest(action: "browser_create", protocolVersion: 2, browser: BrowserCommand(sessionId: session, mediaKind: kind, filename: name)))
        XCTAssertTrue(response.success)
        return (try XCTUnwrap(response.taskId), session, try XCTUnwrap(response.extra?["token"]))
    }
    private func request(_ job: (String,String,String), _ action: String, size: Int64? = nil, hash: String? = nil, offset: Int64? = nil, data: Data? = nil, code: String? = nil) -> IPCRequest {
        IPCRequest(action: action, taskId: job.0, protocolVersion: 2, browser: BrowserCommand(sessionId: job.1, token: job.2, expectedSize: size, offset: offset, data: data?.base64EncodedString(), sha256: hash, selectionProof: "native_action_exact_url", errorCode: code))
    }
    private func ready(_ engine: BrowserTransfers, _ job: (String,String,String)) async throws {
        for _ in 0..<100 {
            let response = await engine.command(request(job, "browser_poll"))
            if response.extra?["status"] == "downloading" { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Job never acquired slot")
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func importData(_ engine: BrowserTransfers, _ job: (String,String,String), _ data: Data) async throws -> IPCResponse {
        try await ready(engine, job)
        let begin = await engine.command(request(job, "browser_begin", size: Int64(data.count), hash: hash(data)))
        XCTAssertTrue(begin.success)
        var offset = 0
        while offset < data.count {
            let part = data.subdata(in: offset..<min(offset+65536,data.count))
            let ack = await engine.command(request(job,"browser_chunk",offset: Int64(offset),data: part)); XCTAssertTrue(ack.success)
            offset += part.count
        }
        return await engine.command(request(job, "browser_finish", hash: hash(data)))
    }
    func testExactFileHashAndNoOverwriteAndNoSecretsInStorage() async throws {
        let (dir, store, _, engine) = try environment(); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data(repeating: 42, count: 190001)
        try Data("existing".utf8).write(to: dir.appendingPathComponent("sample.bin"))
        let job = try await create(engine)
        let done = try await importData(engine, job, bytes); XCTAssertTrue(done.success); XCTAssertEqual(done.extra?["verification"],"VERIFIED")
        let task = try XCTUnwrap(store.getTask(id: UUID(uuidString: job.0)!))
        XCTAssertEqual(task.status,.completed); XCTAssertEqual(task.downloadedBytes,190001)
        XCTAssertEqual(task.browserInfo?.sha256,hash(bytes)); XCTAssertEqual(task.browserInfo?.validationScope,"transport_and_copy")
        XCTAssertNotEqual(task.filename,"sample.bin"); XCTAssertEqual(try Data(contentsOf: task.finalFilePath),bytes)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("sample.bin")),Data("existing".utf8))
        let json = String(data: try JSONEncoder().encode(task), encoding: .utf8)!
        XCTAssertFalse(json.contains(job.1)); XCTAssertFalse(json.contains(job.2)); XCTAssertFalse(json.contains("web.telegram.org"))
    }
    func testConfirmationNeverBecomesAutomaticVerification() async throws {
        let (dir, store, _, engine) = try environment(); defer { try? FileManager.default.removeItem(at: dir) }
        let job = try await create(engine); try await ready(engine,job)
        let pending = await engine.command(request(job,"browser_failure",code:"needs_confirmation")); XCTAssertTrue(pending.success)
        XCTAssertEqual(try store.getTask(id: UUID(uuidString: job.0)!)?.status,.needsConfirmation)
        let confirmation = await engine.command(request(job,"browser_confirm")); XCTAssertTrue(confirmation.success)
        let done = try await importData(engine,job,Data("selected file".utf8)); XCTAssertTrue(done.success)
        let info = try store.getTask(id: UUID(uuidString: job.0)!)?.browserInfo
        XCTAssertEqual(info?.verification,"USER_CONFIRMED"); XCTAssertEqual(info?.selectionProof,"user_confirmed_file")
    }
    func testWrongOffsetOversizedChunkIncompleteAndWrongHashFail() async throws {
        for fault in ["offset","oversize","incomplete","hash"] {
            let (dir, store, _, engine) = try environment(); defer { try? FileManager.default.removeItem(at: dir) }
            let data = Data(repeating: 1,count:65537); let job = try await create(engine); try await ready(engine,job)
            let begin = await engine.command(request(job,"browser_begin",size:Int64(data.count),hash:hash(data))); XCTAssertTrue(begin.success)
            let result: IPCResponse
            switch fault {
            case "offset": result = await engine.command(request(job,"browser_chunk",offset:1,data:Data([1])))
            case "oversize": result = await engine.command(request(job,"browser_chunk",offset:0,data:data))
            case "incomplete": result = await engine.command(request(job,"browser_finish",hash:hash(data)))
            default:
                let first = await engine.command(request(job,"browser_chunk",offset:0,data:data.prefix(65536))); XCTAssertTrue(first.success)
                let last = await engine.command(request(job,"browser_chunk",offset:65536,data:Data([1]))); XCTAssertTrue(last.success)
                result = await engine.command(request(job,"browser_finish",hash:String(repeating:"0",count:64)))
            }
            XCTAssertFalse(result.success,fault)
            let task = try XCTUnwrap(store.getTask(id:UUID(uuidString:job.0)!)); XCTAssertEqual(task.status,.failed)
            XCTAssertFalse(FileManager.default.fileExists(atPath:task.finalFilePath.path))
        }
    }
    func testBadTokenDoesNotCancelAuthorizedJobAndDisconnectDoes() async throws {
        let (dir, store, _, engine) = try environment(); defer { try? FileManager.default.removeItem(at: dir) }
        let job = try await create(engine); try await ready(engine,job)
        let bad = await engine.command(request((job.0,job.1,"wrong"),"browser_cancel")); XCTAssertFalse(bad.success)
        XCTAssertEqual(try store.getTask(id:UUID(uuidString:job.0)!)?.status,.downloading)
        let disconnect = await engine.command(IPCRequest(action:"browser_disconnect",protocolVersion:2,browser:BrowserCommand(sessionId:job.1)))
        XCTAssertTrue(disconnect.success); XCTAssertEqual(try store.getTask(id:UUID(uuidString:job.0)!)?.status,.failed)
    }
    func testSharedTwoSlotsQueueAndCancelRelease() async throws {
        let (dir, store, slots, engine) = try environment(); defer { try? FileManager.default.removeItem(at: dir) }
        let httpA = UUID(), httpB = UUID(); try await slots.acquire(httpA); try await slots.acquire(httpB)
        let job = try await create(engine)
        try await Task.sleep(nanoseconds:30_000_000)
        XCTAssertEqual(try store.getTask(id:UUID(uuidString:job.0)!)?.status,.pending)
        await slots.release(httpA); try await ready(engine,job)
        await engine.cancel(UUID(uuidString:job.0)!)
        let next = try await create(engine); try await ready(engine,next)
        await engine.cancel(UUID(uuidString:next.0)!); await slots.release(httpB)
    }
    func testInvalidImageAndVideoDoNotComplete() async throws {
        for kind in ["video","audio","image"] {
            let (dir, store, _, engine) = try environment(); defer { try? FileManager.default.removeItem(at:dir) }
            let job = try await create(engine,kind:kind)
            let result = try await importData(engine,job,Data("not a media file".utf8))
            XCTAssertFalse(result.success); XCTAssertEqual(try store.getTask(id:UUID(uuidString:job.0)!)?.browserInfo?.errorCode,"validation_failed")
        }
    }
    func testRestartInvalidatesBrowserLocatorAndKeepsLegacyJob() async throws {
        let (dir,store,_,engine) = try environment(); defer { try? FileManager.default.removeItem(at:dir) }
        let job = try await create(engine); try await ready(engine,job)
        let legacy = DownloadTask(url:URL(string:"https://example.com/test.mp4")!,filename:"legacy.mp4",destinationFolder:dir)
        try store.saveTask(legacy)
        let manager = DownloadManager(dbPath:dir.appendingPathComponent("test.sqlite3").path)
        XCTAssertEqual(manager.getTask(id:UUID(uuidString:job.0)!)?.status,.failed)
        XCTAssertEqual(manager.getTask(id:legacy.id)?.status,.pending)
        await engine.cancel(UUID(uuidString:job.0)!)
    }
    func testSocketTransfersFull64KiBChunkAndPrivatePermissions() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:dir) }
        let path = dir.appendingPathComponent("ipc").path; let server = UnixDomainSocketServer(socketPath:path)
        server.requestHandler = { request in IPCResponse(success:true,message:request.browser?.data) }
        try server.start(); defer { server.stop() }
        let permissions = try FileManager.default.attributesOfItem(atPath:path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue,0o600)
        let data = Data(repeating:7,count:65536).base64EncodedString()
        let response = try await Task.detached { try UnixDomainSocketClient(socketPath:path).send(request:IPCRequest(action:"test",browser:BrowserCommand(data:data))) }.value
        XCTAssertEqual(response.message,data)
    }
}

final class RedirectPolicyTests: XCTestCase {
    func testCrossOriginStripsCredentialsAndKeepsRange() {
        var request = URLRequest(url:URL(string:"https://other.example/file.mp4")!)
        for name in ["Cookie","Authorization","Proxy-Authorization","X-Api-Key","Referer"] { request.setValue("secret",forHTTPHeaderField:name) }
        request.setValue("bytes=1-9",forHTTPHeaderField:"Range")
        let redirected = HTTPRedirectPolicy.safeRequest(request,previous:URL(string:"https://first.example/file"),count:1)
        XCTAssertEqual(redirected?.value(forHTTPHeaderField:"Range"),"bytes=1-9")
        for name in ["Cookie","Authorization","Proxy-Authorization","X-Api-Key","Referer"] { XCTAssertNil(redirected?.value(forHTTPHeaderField:name)) }
        XCTAssertEqual(redirected?.httpShouldHandleCookies,false)
    }
    func testSameOriginAndLimitsAndBrowserEndpoints() {
        var request = URLRequest(url:URL(string:"https://same.example/b")!); request.setValue("session",forHTTPHeaderField:"Cookie")
        XCTAssertEqual(HTTPRedirectPolicy.safeRequest(request,previous:URL(string:"https://same.example/a"),count:10)?.value(forHTTPHeaderField:"Cookie"),"session")
        XCTAssertNil(HTTPRedirectPolicy.safeRequest(request,previous:request.url,count:11))
        for url in ["file:///tmp/test","blob:https://example.com/123","https://web.telegram.org/k/stream/redacted"] {
            XCTAssertNil(HTTPRedirectPolicy.safeRequest(URLRequest(url:URL(string:url)!),previous:request.url,count:1))
        }
    }
}

final class NativeHostIntegrationTests: XCTestCase {
    func testRealHostCopiesOnlyAuthorizedCompletedDownloadAndPreservesOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let store = try SQLiteStore(path:root.appendingPathComponent("test.sqlite3").path)
        let engine = BrowserTransfers(store:store,slots:DownloadSlots(),destination:root,notify:{})
        let path = root.appendingPathComponent("ipc").path; let server = UnixDomainSocketServer(socketPath:path)
        server.requestHandler = { request in
            if request.action == "hello" { return IPCResponse(success:request.protocolVersion == AppVersion.protocolVersion,extra:["appVersion":AppVersion.appVersion,"protocolVersion":"\(AppVersion.protocolVersion)"]) }
            return await engine.command(request)
        }
        try server.start(); defer { server.stop() }
        let process = Process(); let input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/internet-downloader-host")
        process.environment = ProcessInfo.processInfo.environment.merging(["IDM_SOCKET_PATH":path]) { _,new in new }
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); defer { try? input.fileHandleForWriting.close(); if process.isRunning { process.terminate() } }
        func exchange(_ request:IPCRequest) async throws -> IPCResponse {
            try await Task.detached {
                var json = try JSONSerialization.jsonObject(with:JSONEncoder().encode(request)) as! [String:Any]
                json["requestId"] = UUID().uuidString
                let data = try JSONSerialization.data(withJSONObject:json); var length = UInt32(data.count).littleEndian
                try input.fileHandleForWriting.write(contentsOf:Data(bytes:&length,count:4)); try input.fileHandleForWriting.write(contentsOf:data)
                var prefix = Data()
                while prefix.count < 4 { let part = output.fileHandleForReading.readData(ofLength:4-prefix.count); if part.isEmpty { throw BrowserFailure.transferFailed }; prefix.append(part) }
                let count = prefix.enumerated().reduce(0) { $0 | (Int($1.element) << (8*$1.offset)) }
                var response = Data()
                while response.count < count { let part = output.fileHandleForReading.readData(ofLength:count-response.count); if part.isEmpty { throw BrowserFailure.transferFailed }; response.append(part) }
                return try JSONDecoder().decode(IPCResponse.self,from:response)
            }.value
        }
        let data = Data(repeating:123,count:32 * 1024 * 1024 + 27); let original = root.appendingPathComponent("Chrome-original.bin"); try data.write(to:original)
        let session = UUID().uuidString
        let created = try await exchange(IPCRequest(action:"browser_create",protocolVersion:2,browser:BrowserCommand(sessionId:session,mediaKind:"file",filename:"import.bin")))
        let id = try XCTUnwrap(created.taskId), token = try XCTUnwrap(created.extra?["token"])
        for _ in 0..<100 {
            let state = try await exchange(IPCRequest(action:"browser_poll",taskId:id,protocolVersion:2,browser:BrowserCommand(sessionId:session,token:token)))
            if state.extra?["status"] == "downloading" { break }; try await Task.sleep(nanoseconds:10_000_000)
        }
        let complete = try await exchange(IPCRequest(action:"browser_copy",taskId:id,protocolVersion:2,browser:BrowserCommand(sessionId:session,token:token,selectionProof:"native_action_exact_url",sourcePath:original.path,downloadId:12,downloadState:"complete")))
        XCTAssertTrue(complete.success); XCTAssertEqual(complete.extra?["status"],"completed")
        let task = try XCTUnwrap(store.getTask(id:UUID(uuidString:id)!))
        XCTAssertEqual(try Data(contentsOf:task.finalFilePath),data); XCTAssertEqual(try Data(contentsOf:original),data)
        XCTAssertEqual(task.browserInfo?.sha256,try BrowserFileValidation.hash(original))
        let rejected = try await exchange(IPCRequest(action:"browser_copy",taskId:UUID().uuidString,protocolVersion:2,browser:BrowserCommand(sessionId:session,token:token,sourcePath:original.path,downloadId:12,downloadState:"complete")))
        XCTAssertFalse(rejected.success)
    }
}

import SQLite3
final class BrowserMigrationAndValidationTests: XCTestCase {
    // Resolve ffmpeg: ENV FFMPEG → /opt/homebrew → /usr/local → which. Nil khi thiếu.
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
    func testOldSchemaMigratesWithoutChangingExistingRows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:dir) }
        let path=dir.appendingPathComponent("migration.sqlite3").path
        let original=DownloadTask(url:URL(string:"https://example.com/old.mp4")!,filename:"old.mp4",destinationFolder:dir,status:.failed,errorMessage:"HTTP 302")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let storedBefore: Data
        do { let store=try SQLiteStore(path:path); try store.saveTask(original); storedBefore = try encoder.encode(XCTUnwrap(store.getTask(id:original.id))) }
        var db:OpaquePointer?; XCTAssertEqual(sqlite3_open(path,&db),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db,"ALTER TABLE tasks DROP COLUMN browser_info",nil,nil,nil),SQLITE_OK);sqlite3_close(db)
        let store=try SQLiteStore(path:path); let migrated=try XCTUnwrap(store.getTask(id:original.id))
        XCTAssertEqual(try encoder.encode(migrated), storedBefore)
        XCTAssertEqual(migrated.url,original.url);XCTAssertEqual(migrated.errorMessage,"HTTP 302");XCTAssertNil(migrated.browserInfo)
        var updated=migrated;updated.browserInfo=BrowserTaskInfo(mediaKind:"video");try store.saveTask(updated)
        XCTAssertEqual(try store.getTask(id:original.id)?.browserInfo?.mediaKind,"video")
    }
    func testVideoDecodeAndDurationAndImageDecode() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:dir)}
        let binary = find_ffmpeg()
        guard let binary, FileManager.default.isExecutableFile(atPath: binary) else { throw XCTSkip("ffmpeg unavailable (FFMPEG → /opt/homebrew → /usr/local → which)") }
        let video=dir.appendingPathComponent("synthetic.mp4")
        let process=Process();process.executableURL=URL(fileURLWithPath:binary);process.standardError=FileHandle.nullDevice;process.standardOutput=FileHandle.nullDevice
        process.arguments=["-v","error","-f","lavfi","-i","testsrc2=size=64x64:rate=10","-t","4","-c:v","libx264","-pix_fmt","yuv420p",video.path]
        try process.run();process.waitUntilExit();XCTAssertEqual(process.terminationStatus,0)
        XCTAssertEqual(try BrowserFileValidation.validate(video,kind:"video",expectedDuration:4),"media_decode_and_transport")
        XCTAssertThrowsError(try BrowserFileValidation.validate(video,kind:"video",expectedDuration:40))
        let image=dir.appendingPathComponent("image.png")
        let png=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aR84AAAAASUVORK5CYII=")!
        try png.write(to:image)
        XCTAssertEqual(try BrowserFileValidation.validate(image,kind:"image",expectedDuration:nil),"image_decode_and_transport")
    }
}
