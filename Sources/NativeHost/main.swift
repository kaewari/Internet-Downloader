import Foundation
import DownloaderCore
import CryptoKit
import Darwin

private let outputLock = NSLock()
private let authorizationLock = NSLock()
private var disconnected = false
private var authorized: [String: (session: String, token: String)] = [:]
private let client = UnixDomainSocketClient(socketPath: ProcessInfo.processInfo.environment["IDM_SOCKET_PATH"] ?? UnixDomainSocketServer.secureDefaultSocketPath)

func readBytes(_ count: Int) -> Data? {
    var data = Data()
    while data.count < count {
        let part = FileHandle.standardInput.readData(ofLength: count - data.count)
        if part.isEmpty { return nil }; data.append(part)
    }
    return data
}
func readMessage() -> Data? {
    guard let prefix = readBytes(4) else { return nil }
    let length = prefix.enumerated().reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
    // Frame 0 hợp lệ nghĩa là EOF đúng giờ: nhượng bộ kết thúc phiên.
    guard length > 0 else { return nil }
    // Frame vượt cap: đọc-bỏ dữ liệu rồi trả về MyApp error frame để extension
    // thấy rõ lý do (không "Native host has exited" và không treo host).
    guard length <= 1024 * 1024 else {
        var drained = 0
        while drained < length {
            let block = min(length - drained, 65536)
            guard let junk = readBytes(block) else { return nil }
            drained += junk.count
        }
        writeMessage(IPCResponse(success: false, message: "Payload vượt giới hạn 1 MiB của native messaging — Cookies quá lớn.",
            extra: ["code": "bad_request"]), requestId: nil)
        return nil
    }
    return readBytes(length)
}
func writeMessage(_ response: IPCResponse, requestId: String?) {
    guard let encoded = try? JSONEncoder().encode(response), var json = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return }
    json["requestId"] = requestId
    guard let data = try? JSONSerialization.data(withJSONObject: json), data.count <= 1024 * 1024 else { return }
    outputLock.withLock {
        var length = UInt32(data.count).littleEndian
        FileHandle.standardOutput.write(Data(bytes: &length, count: 4))
        FileHandle.standardOutput.write(data)
    }
}
func launchOwnApp(front: Bool) {
    let flags = front ? [] : ["-g"]
    func runOpen(_ arguments: [String]) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        try? process.run()
    }
    // 1. The wrapper installed by scripts/install_native_host.sh pins the exact app
    //    bundle that owns this helper, even when the host binary is registered
    //    outside the bundle (e.g. .build/release or a dev stage).
    if let raw = ProcessInfo.processInfo.environment["IDM_APP_PATH"], !raw.isEmpty {
        let candidate = URL(fileURLWithPath: raw).standardizedFileURL
        if candidate.pathExtension == "app", FileManager.default.fileExists(atPath: candidate.path) {
            runOpen(flags + [candidate.path])
            return
        }
    }
    // 2. The helper belongs to this release bundle. Never prefer another install:
    //    Contents/Helpers/internet-downloader-host -> Contents -> <App>.app.
    let path = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    if path.pathExtension == "app", FileManager.default.fileExists(atPath: path.path) {
        runOpen(flags + [path.path])
        return
    }
    // 3. Host registered outside any .app: ask LaunchServices for the app by bundle
    //    id so a browser handoff still auto-launches it instead of dying silently.
    runOpen(flags + ["-b", AppVersion.bundleIdentifier])
}
func send(_ request: IPCRequest) throws -> IPCResponse {
    do { return try client.send(request: request) } catch {
        launchOwnApp(front: request.action == "start_download" || request.action == "browser_create")
        // A cold app start (especially after a reboot) can take several seconds to
        // bind the socket; 3s was too short and made the handoff fail silently.
        for _ in 0..<100 {
            Thread.sleep(forTimeInterval: 0.1)
            if let response = try? client.send(request: request) { return response }
        }
        throw error
    }
}
func checked(_ request: IPCRequest) throws -> IPCResponse {
    let response = try send(request)
    guard response.success else { throw BrowserFailure(rawValue: response.extra?["code"] ?? "") ?? .transferFailed }
    return response
}
func copyCompletedDownload(_ request: IPCRequest) throws -> IPCResponse {
    guard request.protocolVersion == AppVersion.protocolVersion, let id = request.taskId, let input = request.browser,
          let auth = authorizationLock.withLock({ authorized[id] }), auth.session == input.sessionId, auth.token == input.token,
          input.downloadState == "complete", let downloadId = input.downloadId, downloadId >= 0,
          let path = input.sourcePath, path.hasPrefix("/"), !path.contains("\0") else { throw BrowserFailure.invalidTransfer }
    let fd = open(path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { throw BrowserFailure.transferFailed }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
    var before = stat()
    guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG, before.st_size >= 0 else { throw BrowserFailure.invalidTransfer }
    var digest = SHA256(); var seen = Date()
    while let part = try file.read(upToCount: 65536), !part.isEmpty {
        if authorizationLock.withLock({ disconnected }) { throw BrowserFailure.reconnect }
        digest.update(data: part)
        if Date().timeIntervalSince(seen) > 3 { _ = try checked(IPCRequest(action: "browser_poll", taskId: id, protocolVersion: AppVersion.protocolVersion, browser: BrowserCommand(sessionId: auth.session, token: auth.token))); seen = Date() }
    }
    let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
    _ = try checked(IPCRequest(action: "browser_begin", taskId: id, protocolVersion: AppVersion.protocolVersion,
        browser: BrowserCommand(sessionId: auth.session, token: auth.token, filename: URL(fileURLWithPath: path).lastPathComponent,
            expectedSize: before.st_size, sha256: hash, selectionProof: input.selectionProof)))
    try file.seek(toOffset: 0)
    var offset: Int64 = 0; digest = SHA256()
    while let part = try file.read(upToCount: 65536), !part.isEmpty {
        if authorizationLock.withLock({ disconnected }) { throw BrowserFailure.reconnect }
        digest.update(data: part)
        _ = try checked(IPCRequest(action: "browser_chunk", taskId: id, protocolVersion: AppVersion.protocolVersion,
            browser: BrowserCommand(sessionId: auth.session, token: auth.token, offset: offset, data: part.base64EncodedString())))
        offset += Int64(part.count)
    }
    var after = stat()
    let copiedHash = digest.finalize().map { String(format: "%02x", $0) }.joined()
    guard fstat(fd, &after) == 0, before.st_ino == after.st_ino, before.st_size == after.st_size,
          before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
          offset == before.st_size, copiedHash == hash else { throw BrowserFailure.hashMismatch }
    let result = try checked(IPCRequest(action: "browser_finish", taskId: id, protocolVersion: AppVersion.protocolVersion,
        browser: BrowserCommand(sessionId: auth.session, token: auth.token, sha256: hash)))
    _ = authorizationLock.withLock { authorized.removeValue(forKey: id) }
    return result
}
func process(_ data: Data) {
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let requestId = object?["requestId"] as? String
    var request: IPCRequest?
    do {
        request = try JSONDecoder().decode(IPCRequest.self, from: data)
    } catch {
        // JSON decode fail (không còn return nil im lặng): trả error frame rõ
        // để extension nhìn thấy và không tưởng app host đã chết.
        writeMessage(IPCResponse(success: false, message: "Native host không đọc được yêu cầu (JSON sai định dạng).",
            extra: ["code": "bad_request"]), requestId: requestId)
        return
    }
    do {
        let decoded = request!
        let response: IPCResponse
        if decoded.action == "browser_copy" { response = try copyCompletedDownload(decoded) }
        else {
            // Only sessions this host created can transfer bytes or disconnect.
            if decoded.action.hasPrefix("browser_"), decoded.action != "browser_create" {
                guard let id = decoded.taskId, let input = decoded.browser,
                      let auth = authorizationLock.withLock({ authorized[id] }), auth.token == input.token, auth.session == input.sessionId else { throw BrowserFailure.invalidTransfer }
            }
            if decoded.action == "browser_create" {
                let hello = try checked(IPCRequest(action: "hello", protocolVersion: AppVersion.protocolVersion))
                guard hello.extra?["appVersion"] == AppVersion.appVersion, hello.extra?["protocolVersion"] == String(AppVersion.protocolVersion) else { throw BrowserFailure.protocolMismatch }
            }
            response = try send(decoded)
            if decoded.action == "browser_create", response.success, let id = response.taskId,
               let token = response.extra?["token"], let session = decoded.browser?.sessionId {
                authorizationLock.withLock { authorized[id] = (session, token) }
                launchOwnApp(front: true)
            }
            if decoded.action == "browser_cancel" || (decoded.action == "browser_failure" && decoded.browser?.errorCode != "needs_confirmation") {
                if let id = decoded.taskId { _ = authorizationLock.withLock { authorized.removeValue(forKey: id) } }
            }
            if decoded.action == "start_download", response.success { launchOwnApp(front: true) }
        }
        writeMessage(response, requestId: requestId)
    } catch {
        let reason = error as? BrowserFailure ?? .transferFailed
        if let request, let id = request.taskId, let input = request.browser,
           let auth = authorizationLock.withLock({ authorized[id] }), auth.token == input.token {
            _ = try? send(IPCRequest(action: "browser_failure", taskId: id, protocolVersion: AppVersion.protocolVersion, browser: BrowserCommand(sessionId: auth.session, token: auth.token, errorCode: reason.rawValue)))
        }
        writeMessage(IPCResponse(success: false, taskId: request?.taskId, message: reason.localizedDescription,
            extra: ["code": reason.rawValue, "stage": "native_host"]), requestId: requestId)
    }
}
// Chrome launches the host with no extra argv (manifest allowed_origins already
// gates the caller). Only reject on explicit mismatch; missing arg = allow with
// a stderr note (B7 revised: fail-closed on mismatch, not on Chrome's normal launch).
if CommandLine.arguments.count > 1 && CommandLine.arguments[1] != AppVersion.extensionAllowedOrigin {
    fputs("internet-downloader-host: rejected caller origin\n", stderr)
    exit(1)
}
let group = DispatchGroup()
while let data = readMessage() { group.enter(); DispatchQueue.global().async { process(data); group.leave() } }
authorizationLock.withLock { disconnected = true }
group.wait()
let sessions = authorizationLock.withLock { Set(authorized.values.map(\.session)) }
for session in sessions { _ = try? send(IPCRequest(action: "browser_disconnect", protocolVersion: AppVersion.protocolVersion, browser: BrowserCommand(sessionId: session))) }
