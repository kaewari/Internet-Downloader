import Foundation
import Darwin

public final class UnixDomainSocketServer: @unchecked Sendable {
    public static let defaultSocketPath = "/tmp/com.internetdownloader.ipc.sock"
    private let socketPath: String
    private var serverFd: Int32 = -1
    private var isRunning = false
    private let queue = DispatchQueue(label: "com.internetdownloader.ipc.server", attributes: .concurrent)
    public var requestHandler: (@Sendable (IPCRequest) async -> IPCResponse)?

    public init(socketPath: String = defaultSocketPath) {
        self.socketPath = socketPath
    }

    deinit {
        stop()
    }

    public func start() throws {
        stop()

        // Remove old socket file if exists
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.serverFd = fd

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw NSError(domain: "IPCServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Socket path too long"])
        }

        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                _ = pathBytes.withUnsafeBufferPointer { src in
                    strncpy(dest, src.baseAddress!, maxPathLen)
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(fd, saPtr, addrLen)
            }
        }

        guard bindResult == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE)
        }

        guard listen(fd, 10) == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        chmod(socketPath, 0o600)
        isRunning = true
        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    public func stop() {
        let ownedSocket = serverFd >= 0
        isRunning = false
        if serverFd >= 0 {
            close(serverFd)
            serverFd = -1
        }
        if ownedSocket { unlink(socketPath) }
    }

    private func acceptLoop() {
        while isRunning && serverFd >= 0 {
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    Darwin.accept(serverFd, saPtr, &clientLen)
                }
            }

            guard clientFd >= 0 else {
                if !isRunning { break }
                continue
            }

            Task { [weak self] in
                await self?.handleClient(clientFd: clientFd)
            }
        }
    }

    private func handleClient(clientFd: Int32) async {
        defer { close(clientFd) }

        SocketFrame.configure(clientFd)
        do {
            let request = try JSONDecoder().decode(IPCRequest.self, from: SocketFrame.receive(clientFd))
            let response = await requestHandler?(request) ?? IPCResponse(success: false, message: "No handler registered")
            try SocketFrame.send(clientFd, data: JSONEncoder().encode(response))
        } catch {
            let response = IPCResponse(success: false, message: "Invalid IPC frame")
            try? SocketFrame.send(clientFd, data: JSONEncoder().encode(response))
        }
    }
}
