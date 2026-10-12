import Foundation
import CryptoKit
import ImageIO

public enum BrowserFailure: String, Error, LocalizedError {
    case protocolMismatch = "protocol_mismatch", sourceChanged = "source_changed"
    case invalidTransfer = "invalid_transfer", transferFailed = "browser_transfer_failed"
    case incompleteFile = "incomplete_file", hashMismatch = "hash_mismatch"
    case validationFailed = "validation_failed", reconnect = "browser_reconnect"
    case websiteSaveUnavailable = "website_save_unavailable"
    case cancelled = "browser_cancelled"
    public var stage: String {
        switch self {
        case .protocolMismatch: return "handshake"
        case .sourceChanged, .websiteSaveUnavailable: return "discovery"
        case .validationFailed: return "validation"
        default: return "browser_transfer"
        }
    }
    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Đã hủy phiên tải trình duyệt. Chọn lại mục nếu muốn tải tiếp."
        case .protocolMismatch: return "App/extension chưa cùng phiên bản. Nạp lại bản mới."
        case .sourceChanged: return "Mục được chọn đã thay đổi. Chọn lại trong Chrome."
        case .reconnect: return "Phiên Chrome đã mất. Chọn lại mục trong extension."
        case .websiteSaveUnavailable: return "Telegram không có nút Download/Save gốc khả dụng cho mục này."
        case .invalidTransfer: return "Phiên/chunk chuyển file không hợp lệ."
        case .incompleteFile: return "File chưa đủ byte của bản Chrome đã lưu."
        case .hashMismatch: return "Hash bản sao không khớp bản Chrome đã lưu."
        case .validationFailed: return "File không qua kiểm tra định dạng hoặc decode."
        case .transferFailed: return "Không hoàn tất chuyển file từ Chrome."
        }
    }
}

public enum BrowserFileValidation {
    public static func hash(_ path: URL) throws -> String {
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw BrowserFailure.transferFailed }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw BrowserFailure.transferFailed }
        var digest = SHA256()
        while let part = try handle.read(upToCount: 65536), !part.isEmpty { digest.update(data: part) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func validate(_ path: URL, kind: String, expectedDuration: Double?) throws -> String {
        if kind == "image" {
            guard let source = CGImageSourceCreateWithURL(path as CFURL, nil), CGImageSourceGetCount(source) > 0 else { throw BrowserFailure.validationFailed }
            for index in 0..<CGImageSourceGetCount(source) {
                guard let image = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary), image.width > 0, image.height > 0 else { throw BrowserFailure.validationFailed }
            }
            return "image_decode_and_transport"
        }
        guard kind == "video" || kind == "audio" else { return "transport_and_copy" }
        let probe = try run("ffprobe", ["-v", "error", "-protocol_whitelist", "file,pipe", "-show_streams", "-show_format", "-of", "json", path.path], directory: path.deletingLastPathComponent())
        guard let object = try JSONSerialization.jsonObject(with: probe) as? [String: Any],
              let streams = object["streams"] as? [[String: Any]], streams.contains(where: { $0["codec_type"] as? String == kind }),
              let format = object["format"] as? [String: Any], let durationText = format["duration"] as? String,
              let duration = Double(durationText), duration.isFinite, duration > 0 else { throw BrowserFailure.validationFailed }
        if let expected = expectedDuration, abs(duration - expected) > max(2, expected * 0.02) { throw BrowserFailure.incompleteFile }
        for point in [0, duration / 2, max(0, duration - 2)] {
            _ = try run("ffmpeg", ["-v", "error", "-xerror", "-nostdin", "-protocol_whitelist", "file,pipe", "-ss", String(point), "-i", path.path, "-t", "1", "-f", "null", "-"], directory: path.deletingLastPathComponent())
        }
        return "media_decode_and_transport"
    }

    private static func run(_ tool: String, _ arguments: [String], directory: URL) throws -> Data {
        guard let binary = ["/opt/homebrew/bin/", "/usr/local/bin/"].map({ $0 + tool }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw BrowserFailure.validationFailed }
        let output = directory.appendingPathComponent("validation-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: binary); process.arguments = arguments
        process.standardOutput = handle; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); throw BrowserFailure.validationFailed }
        guard process.terminationStatus == 0 else { throw BrowserFailure.validationFailed }
        try handle.synchronize()
        let attrs = try FileManager.default.attributesOfItem(atPath: output.path)
        guard (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 262144 else { throw BrowserFailure.validationFailed }
        let data = try Data(contentsOf: output)
        guard data.count <= 262144 else { throw BrowserFailure.validationFailed }
        return data
    }
}
