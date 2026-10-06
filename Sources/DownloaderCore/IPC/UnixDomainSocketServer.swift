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

        isRunning = true
        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    public func stop() {
        isRunning = false
        if serverFd >= 0 {
            close(serverFd)
            serverFd = -1
        }
        unlink(socketPath)
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

        // Read 4-byte length prefix
        var lengthBuffer = UInt32(0)
        let bytesRead = read(clientFd, &lengthBuffer, 4)
        guard bytesRead == 4 else { return }

        let payloadLength = Int(UInt32(bigEndian: lengthBuffer))
        guard payloadLength > 0 && payloadLength <= 10 * 1024 * 1024 else { return } // Max 10MB

        var payloadData = Data(count: payloadLength)
        var totalRead = 0

        let readSuccess = payloadData.withUnsafeMutableBytes { (rawPtr: UnsafeMutableRawBufferPointer) -> Bool in
            guard let baseAddress = rawPtr.baseAddress else { return false }
            while totalRead < payloadLength {
                let r = read(clientFd, baseAddress.advanced(by: totalRead), payloadLength - totalRead)
                if r <= 0 { return false }
                totalRead += r
            }
            return true
        }

        guard readSuccess else { return }

        do {
            let request = try JSONDecoder().decode(IPCRequest.self, from: payloadData)
            let response: IPCResponse
            if let handler = self.requestHandler {
                response = await handler(request)
            } else {
                response = IPCResponse(success: false, message: "No handler registered")
            }

            if let respData = try? JSONEncoder().encode(response) {
                var len = UInt32(respData.count).bigEndian
                _ = write(clientFd, &len, 4)
                _ = respData.withUnsafeBytes { rawPtr in
                    write(clientFd, rawPtr.baseAddress!, respData.count)
                }
            }
        } catch {
            let errResp = IPCResponse(success: false, message: "Malformed request: \(error.localizedDescription)")
            if let respData = try? JSONEncoder().encode(errResp) {
                var len = UInt32(respData.count).bigEndian
                _ = write(clientFd, &len, 4)
                _ = respData.withUnsafeBytes { rawPtr in
                    write(clientFd, rawPtr.baseAddress!, respData.count)
                }
            }
        }
    }
}
