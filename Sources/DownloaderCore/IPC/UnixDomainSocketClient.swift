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

        // Encode and send payload
        let reqData = try JSONEncoder().encode(request)
        var len = UInt32(reqData.count).bigEndian
        _ = write(fd, &len, 4)
        _ = reqData.withUnsafeBytes { rawPtr in
            write(fd, rawPtr.baseAddress!, reqData.count)
        }

        // Read response length prefix
        var respLenBuf = UInt32(0)
        let bytesRead = read(fd, &respLenBuf, 4)
        guard bytesRead == 4 else {
            throw NSError(domain: "IPCClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to read response length"])
        }

        let respLength = Int(UInt32(bigEndian: respLenBuf))
        guard respLength > 0 && respLength <= 10 * 1024 * 1024 else {
            throw NSError(domain: "IPCClient", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid response size: \(respLength)"])
        }

        var respData = Data(count: respLength)
        var totalRead = 0
        let readSuccess = respData.withUnsafeMutableBytes { (rawPtr: UnsafeMutableRawBufferPointer) -> Bool in
            guard let baseAddress = rawPtr.baseAddress else { return false }
            while totalRead < respLength {
                let r = read(fd, baseAddress.advanced(by: totalRead), respLength - totalRead)
                if r <= 0 { return false }
                totalRead += r
            }
            return true
        }

        guard readSuccess else {
            throw NSError(domain: "IPCClient", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to read full response payload"])
        }

        return try JSONDecoder().decode(IPCResponse.self, from: respData)
    }
}
