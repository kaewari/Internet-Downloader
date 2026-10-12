import Foundation
import Darwin

public final class UnixDomainSocketClient: Sendable {
    private let socketPath: String

    public init(socketPath: String = UnixDomainSocketServer.defaultSocketPath) {
        self.socketPath = socketPath
    }

    public func send(request: IPCRequest) throws -> IPCResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw NSError(domain: "IPCClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Socket path too long"])
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
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.connect(fd, saPtr, addrLen)
            }
        }

        guard connectResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
        }

        SocketFrame.configure(fd)
        try SocketFrame.send(fd, data: JSONEncoder().encode(request))
        return try JSONDecoder().decode(IPCResponse.self, from: SocketFrame.receive(fd))
    }
}
