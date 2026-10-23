import Foundation
import CryptoKit
import Security

public actor BrowserTransfers {
    private struct Transfer {
        var session: String
        var token: String
        var seen = Date()
        var waiting: Task<Void, Never>?
        var ownsSlot = false
        var writer: FileHandle?
        var bytes: Int64 = 0
        var digest = SHA256()
        var expectedSize: Int64?
        var sourceHash: String?
        var expectedDuration: Double?
        var confirmed = false
    }
    private let store: SQLiteStore
    private let slots: DownloadSlots
    private let destination: URL
    private let notify: @Sendable () -> Void
    private var transfers: [UUID: Transfer] = [:]
    private var timer: Task<Void, Never>?

    public init(store: SQLiteStore, slots: DownloadSlots, destination: URL, notify: @escaping @Sendable () -> Void) {
        self.store = store; self.slots = slots; self.destination = destination; self.notify = notify
    }

    public func command(_ request: IPCRequest) async -> IPCResponse {
        do {
            guard request.protocolVersion == AppVersion.protocolVersion else { throw BrowserFailure.protocolMismatch }
            guard let input = request.browser else { throw BrowserFailure.invalidTransfer }
            if request.action == "browser_create" { return try create(input) }
            if request.action == "browser_disconnect" {
                for (id, transfer) in transfers where transfer.session == input.sessionId { await fail(id, .reconnect) }
                return IPCResponse(success: true)
            }
            guard let text = request.taskId, let id = UUID(uuidString: text), var transfer = transfers[id],
                  transfer.token == input.token, transfer.session == input.sessionId,
                  var task = try store.getTask(id: id) else { throw BrowserFailure.invalidTransfer }
            transfer.seen = Date(); transfers[id] = transfer
            switch request.action {
            case "browser_poll": return reply(task, token: nil)
            case "browser_cancel": await fail(id, .cancelled); return IPCResponse(success: true)
            case "browser_failure":
                if input.errorCode == "needs_confirmation" {
                    guard task.status == .downloading else { throw BrowserFailure.invalidTransfer }
                    task.status = .needsConfirmation; task.browserInfo?.phase = "needs_confirmation"
                    try store.saveTask(task); transfers[id]?.ownsSlot = false; await slots.release(id); notify()
                } else { await fail(id, BrowserFailure(rawValue: input.errorCode ?? "") ?? .transferFailed) }
                return IPCResponse(success: true)
            case "browser_confirm":
                guard task.status == .needsConfirmation else { throw BrowserFailure.invalidTransfer }
                transfers[id]?.confirmed = true; task.status = .pending; task.browserInfo?.phase = "queued"
                try store.saveTask(task); enqueue(id); return reply(task, token: nil)
            case "browser_begin":
                guard task.status == .downloading, transfer.writer == nil, transfer.ownsSlot,
                      let size = input.expectedSize, size >= 0, let hash = input.sha256, hash.count == 64,
                      hash.allSatisfy({ $0.isHexDigit }),
                      transfer.confirmed || input.selectionProof == "native_action_exact_url" else { throw BrowserFailure.invalidTransfer }
                let proof = transfer.confirmed ? "user_confirmed_file" : "native_action_exact_url"
                if let name = input.filename { task.filename = safeFilename(name) }
                try FileManager.default.createDirectory(at: task.tempDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let fd = open(staging(task).path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
                guard fd >= 0 else { throw BrowserFailure.transferFailed }
                transfers[id]?.writer = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                transfers[id]?.expectedSize = size; transfers[id]?.sourceHash = hash
                task.totalBytes = size; task.browserInfo?.selectionProof = proof; task.browserInfo?.phase = "importing"
                try store.saveTask(task); notify(); return reply(task, token: nil)
            case "browser_chunk":
                guard task.status == .downloading, let writer = transfer.writer,
                      input.offset == transfer.bytes, let encoded = input.data, encoded.count <= 87384,
                      let data = Data(base64Encoded: encoded), !data.isEmpty, data.count <= 65536,
                      let size = transfer.expectedSize, transfer.bytes + Int64(data.count) <= size else { throw BrowserFailure.invalidTransfer }
                try writer.write(contentsOf: data)
                transfer.bytes += Int64(data.count); transfer.digest.update(data: data); transfers[id] = transfer
                task.downloadedBytes = transfer.bytes; try store.saveTask(task); notify(); return reply(task, token: nil)
            case "browser_finish":
                guard task.status == .downloading, let writer = transfer.writer, transfer.expectedSize == transfer.bytes else { throw BrowserFailure.incompleteFile }
                try writer.synchronize(); try writer.close(); transfers[id]?.writer = nil
                let hash = transfer.digest.finalize().map { String(format: "%02x", $0) }.joined()
                guard hash == transfer.sourceHash, hash == input.sha256, try BrowserFileValidation.hash(staging(task)) == hash else { throw BrowserFailure.hashMismatch }
                task.status = .assembling; task.browserInfo?.phase = "validating"; try store.saveTask(task); notify()
                let file = staging(task); let kind = task.browserInfo?.mediaKind ?? "file"; let duration = transfer.expectedDuration
                let scope = try await Task.detached { try BrowserFileValidation.validate(file, kind: kind, expectedDuration: duration) }.value
                guard transfers[id]?.token == transfer.token, try store.getTask(id: id)?.status == .assembling else { throw BrowserFailure.reconnect }
                // Validate again before publication; never overwrite an existing file.
                guard try BrowserFileValidation.hash(file) == hash else { throw BrowserFailure.hashMismatch }
                task.filename = try publish(file, task: task)
                task.status = .completed; task.browserInfo?.phase = "completed"; task.browserInfo?.sha256 = hash
                task.browserInfo?.validationScope = scope; task.browserInfo?.verification = transfer.confirmed ? "USER_CONFIRMED" : "VERIFIED"
                try store.saveTask(task); await cleanup(id, task: task); notify(); return reply(task, token: nil)
            default: throw BrowserFailure.invalidTransfer
            }
        } catch {
            let reason = error as? BrowserFailure ?? .transferFailed
            if let text = request.taskId, let id = UUID(uuidString: text), let transfer = transfers[id], transfer.token == request.browser?.token { await fail(id, reason) }
            return IPCResponse(success: false, taskId: request.taskId, message: reason.localizedDescription, extra: ["code": reason.rawValue, "stage": reason.stage])
        }
    }

    private func create(_ input: BrowserCommand) throws -> IPCResponse {
        guard let session = input.sessionId, UUID(uuidString: session) != nil,
              let kind = input.mediaKind, ["video", "audio", "image", "file"].contains(kind), transfers.count < 100 else { throw BrowserFailure.invalidTransfer }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw BrowserFailure.transferFailed }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        if let duration = input.expectedDuration, !duration.isFinite || duration <= 0 { throw BrowserFailure.invalidTransfer }
        let name = safeFilename(input.filename ?? "Attachment Telegram.bin")
        let folder = DownloadManager.categorizedFolder(for: name, baseFolder: destination)
        // Inert metadata marker, never a media URL or restartable locator.
        var task = DownloadTask(url: URL(string: "about:blank")!, filename: name, destinationFolder: folder, segmentsCount: 1)
        task.browserInfo = BrowserTaskInfo(mediaKind: kind)
        try store.saveTask(task)
        transfers[task.id] = Transfer(session: session, token: token, expectedDuration: input.expectedDuration)
        if timer == nil { timer = Task { while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000_000); await self.expire() } } }
        enqueue(task.id); notify(); return reply(task, token: token)
    }

    private func enqueue(_ id: UUID) {
        transfers[id]?.waiting = Task {
            do {
                try await slots.acquire(id)
                guard transfers[id] != nil, var task = try store.getTask(id: id), task.status == .pending else { await slots.release(id); return }
                transfers[id]?.ownsSlot = true; task.status = .downloading; task.browserInfo?.phase = "saving_browser"
                try store.saveTask(task); notify()
            } catch { await fail(id, .reconnect) }
        }
    }

    private func expire() async {
        for (id, transfer) in transfers where Date().timeIntervalSince(transfer.seen) > 30 { await fail(id, .reconnect) }
    }

    public func cancel(_ id: UUID) async { await fail(id, .cancelled) }

    private func fail(_ id: UUID, _ reason: BrowserFailure) async {
        guard let task = try? store.getTask(id: id) else { return }
        var failed = task
        if task.status != .completed {
            failed.status = .failed; failed.errorMessage = reason.localizedDescription
            failed.browserInfo?.phase = "failed"; failed.browserInfo?.errorCode = reason.rawValue; failed.browserInfo?.errorStage = reason.stage
            try? store.saveTask(failed)
        }
        await cleanup(id, task: task); notify()
    }

    private func cleanup(_ id: UUID, task: DownloadTask) async {
        guard let transfer = transfers.removeValue(forKey: id) else { return }
        transfer.waiting?.cancel(); try? transfer.writer?.close()
        if transfers.isEmpty { timer?.cancel(); timer = nil }
        if transfer.ownsSlot { await slots.release(id) }
        try? FileManager.default.removeItem(at: task.tempDirectory)
    }

    private func staging(_ task: DownloadTask) -> URL { task.tempDirectory.appendingPathComponent("browser-part") }
    private func safeFilename(_ input: String) -> String {
        let name = URL(fileURLWithPath: input).lastPathComponent.replacingOccurrences(of: "\0", with: "").prefix(180)
        return name.isEmpty || name == "." || name == ".." ? "attachment.bin" : String(name)
    }
    private func publish(_ source: URL, task: DownloadTask) throws -> String {
        let base = URL(fileURLWithPath: task.filename)
        for index in 0..<1000 {
            let suffix = index == 0 ? "" : " [\(task.id.uuidString.prefix(8))-\(index)]"
            let name = base.deletingPathExtension().lastPathComponent + suffix + (base.pathExtension.isEmpty ? "" : "." + base.pathExtension)
            let target = task.destinationFolder.appendingPathComponent(name)
            if link(source.path, target.path) == 0 { return name }
            if errno != EEXIST { throw BrowserFailure.transferFailed }
        }
        throw BrowserFailure.transferFailed
    }
    private func reply(_ task: DownloadTask, token: String?) -> IPCResponse {
        var extra = ["protocolVersion": "\(AppVersion.protocolVersion)", "appVersion": AppVersion.appVersion, "status": task.status.rawValue,
                     "phase": task.browserInfo?.phase ?? "", "verification": task.browserInfo?.verification ?? "NOT VERIFIED"]
        if let token { extra["token"] = token }
        return IPCResponse(success: true, taskId: task.id.uuidString, extra: extra)
    }
}
