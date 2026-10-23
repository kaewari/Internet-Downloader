import Foundation
import Darwin

public final class UnixDomainSocketServer: @unchecked Sendable {
    /// Legacy socket path in the shared /tmp directory (predictable name).
    /// Kept only as a client fallback for pre-update installs — the server no
    /// longer listens here (B4). New servers listen on `secureDefaultSocketPath`.
    /// - Deprecated: Use `secureDefaultSocketPath`. Do not bind new servers here.
    public static let defaultSocketPath = "/tmp/com.internetdownloader.ipc.sock"

    /// Per-user socket path (B4): Application Support/InternetDownloader under
    /// the user's home (dir created with mode 0700), falling back to a
    /// per-uid file in the temporary directory.
    public static var secureDefaultSocketPath: String {
        let fm = FileManager.default
        if let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return base.appendingPathComponent("InternetDownloader/ipc.sock", isDirectory: false).path
        }
        return fm.temporaryDirectory
            .appendingPathComponent("com.internetdownloader.\(getuid()).ipc.sock", isDirectory: false).path
    }

    /// Maps a requested path to the path the server actually binds (B4).
    /// The legacy /tmp path is transparently redirected to the per-user path so
    /// existing in-repo callers keep working without touching the insecure node.
    public static func effectiveSocketPath(for path: String) -> String {
        path == defaultSocketPath ? secureDefaultSocketPath : path
    }

    /// Cap on concurrently-handled connections (B8): back-pressure instead of
    /// unbounded Task spawning (fd exhaustion / DoS).
    public static let maxConcurrentConnections = 8
    /// Short idle timeout applied to accepted client sockets (B8).
    public static let idleTimeoutSeconds = 10

    private let socketPath: String
    // B11: all mutable server state is guarded by stateLock.
    private let stateLock = NSLock()
    private var _serverFd: Int32 = -1
    private var _isRunning = false
    private var _requestHandler: (@Sendable (IPCRequest) async -> IPCResponse)?
    private let connectionSemaphore = DispatchSemaphore(value: maxConcurrentConnections)
    private let acceptQueue = DispatchQueue(label: "com.internetdownloader.ipc.server.accept")

    public var requestHandler: (@Sendable (IPCRequest) async -> IPCResponse)? {
        get { stateLock.withLock { _requestHandler } }
        set { stateLock.withLock { _requestHandler = newValue } }
    }

    public init(socketPath: String = secureDefaultSocketPath) {
        self.socketPath = socketPath
    }

    deinit {
        stop()
    }

    public func start() throws {
        stop()

        // B4: resolve to the per-user path; create the parent dir (0700) first.
        let bindPath = Self.effectiveSocketPath(for: socketPath)
        let dir = URL(fileURLWithPath: bindPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // Harden a pre-existing dir too (it may predate this fix with lax perms).
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: dir.path)

        // Remove a stale socket node from a previous run before binding.
        unlink(bindPath)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = bindPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw NSError(domain: "IPCServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Socket path too long"])
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var bound = false
        defer { if !bound { close(fd) } }

        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                _ = pathBytes.withUnsafeBufferPointer { src in
                    strncpy(dest, src.baseAddress!, maxPathLen)
                }
            }
        }

        // B4: restrict the socket node's permissions BEFORE bind/listen so there
        // is no chmod-after-bind window. (chmod is re-applied right after bind,
        // still before listen, as belt & braces.)
        let oldMask = umask(0o077)
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(fd, saPtr, addrLen)
            }
        }
        umask(oldMask)

        guard bindResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE)
        }
        chmod(bindPath, 0o600)

        guard listen(fd, 10) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        stateLock.withLock {
            _serverFd = fd
            _isRunning = true
        }
        bound = true
        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    public func stop() {
        let fd = stateLock.withLock { () -> Int32 in
            let owned = _serverFd
            _serverFd = -1
            _isRunning = false
            return owned
        }
        if fd >= 0 {
            close(fd)
            // Only unlink the node this server actually bound (B4).
            unlink(Self.effectiveSocketPath(for: socketPath))
        }
    }

    private func acceptLoop() {
        while true {
            let (running, fd) = stateLock.withLock { (_isRunning, _serverFd) }
            guard running, fd >= 0 else { break }
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    Darwin.accept(fd, saPtr, &clientLen)
                }
            }

            guard clientFd >= 0 else {
                if !stateLock.withLock({ _isRunning }) { break }
                continue
            }

            // B8: bound the number of in-flight handlers; the accept thread
            // blocks here instead of spawning unbounded Tasks.
            connectionSemaphore.wait()
            Task { [weak self] in
                defer { self?.connectionSemaphore.signal() }
                guard let self else { close(clientFd); return }
                // B4: only our own uid may talk to this socket.
                guard self.isPeerAllowed(clientFd) else { close(clientFd); return }
                await self.handleClient(clientFd: clientFd)
            }
        }
    }

    /// B4 peer check: the connecting process must run as our uid.
    /// Uses getpeereid where available; falls back to verifying ownership of
    /// the socket node (dir is 0700, node is 0600, so a foreign-owned node is
    /// already suspicious).
    private func isPeerAllowed(_ clientFd: Int32) -> Bool {
        var euid = uid_t(0)
        var egid = gid_t(0)
        if getpeereid(clientFd, &euid, &egid) == 0 {
            return euid == getuid()
        }
        var st = stat()
        let node = Self.effectiveSocketPath(for: socketPath)
        if stat(node, &st) == 0 {
            return st.st_uid == getuid()
        }
        return false
    }

    private func handleClient(clientFd: Int32) async {
        defer { close(clientFd) }

        // B8: short idle timeout so a stalled peer cannot pin a handler slot.
        SocketFrame.configure(clientFd, timeoutSeconds: Self.idleTimeoutSeconds)
        do {
            let frame: Data
            do {
                frame = try SocketFrame.receive(clientFd)
            } catch let error as POSIXError where error.code == .EMSGSIZE {
                // B10: oversize frame — distinct from a bad-JSON payload.
                let response = IPCResponse(
                    success: false,
                    message: "IPC frame vượt giới hạn 1 MiB — từ chối (oversize).",
                    extra: ["code": "oversize", "stage": "ipc_frame"])
                try? SocketFrame.send(clientFd, data: JSONEncoder().encode(response))
                return
            }
            let request: IPCRequest
            do {
                request = try JSONDecoder().decode(IPCRequest.self, from: frame)
            } catch {
                // B10: malformed JSON — distinct from oversize / handler errors.
                let detail: String
                if error is DecodingError {
                    detail = "IPC JSON không hợp lệ (decode thất bại)."
                } else {
                    detail = "Không đọc được IPC frame."
                }
                let response = IPCResponse(
                    success: false, message: detail,
                    extra: ["code": "bad_json", "stage": "ipc_decode"])
                try? SocketFrame.send(clientFd, data: JSONEncoder().encode(response))
                return
            }
            let response = await requestHandler?(request)
                ?? IPCResponse(
                    success: false, message: "No handler registered",
                    extra: ["code": "no_handler", "stage": "ipc_dispatch"])
            try SocketFrame.send(clientFd, data: JSONEncoder().encode(response))
        } catch {
            // B10: send-side / handler failure — keep a code + stage, never the
            // bare "Invalid IPC frame" bucket for everything.
            let response = IPCResponse(
                success: false, message: "Lỗi IPC khi trả lời (handler/send thất bại).",
                extra: ["code": "handler_failed", "stage": "ipc_reply"])
            try? SocketFrame.send(clientFd, data: JSONEncoder().encode(response))
        }
    }
}
