import Foundation
import Darwin

// Both directions must handle partial reads/writes; a 64 KiB transfer is not
// guaranteed to fit in one socket write.
enum SocketFrame {
    static let maximum = 1024 * 1024
    static func configure(_ fd: Int32) {
        var timeout = timeval(tv_sec: 40, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }
    static func readData(_ fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw POSIXError(.EIO) }
                offset += n
            }
        }
        return data
    }
    static func receive(_ fd: Int32) throws -> Data {
        let prefix = try readData(fd, count: 4)
        let size = prefix.reduce(0) { ($0 << 8) | Int($1) }
        guard size > 0, size <= maximum else { throw POSIXError(.EMSGSIZE) }
        return try readData(fd, count: size)
    }
    static func send(_ fd: Int32, data: Data) throws {
        guard data.count > 0, data.count <= maximum else { throw POSIXError(.EMSGSIZE) }
        var size = UInt32(data.count).bigEndian
        var frame = Data(bytes: &size, count: 4); frame.append(data)
        try frame.withUnsafeBytes { buffer in
            var offset = 0
            while offset < frame.count {
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), frame.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw POSIXError(.EIO) }
                offset += n
            }
        }
    }
}
