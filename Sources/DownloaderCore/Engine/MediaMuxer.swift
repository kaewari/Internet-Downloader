import Foundation

/// Ghép video-only + audio-only thành một file có đủ hình và tiếng.
///
/// Nguồn DASH (YouTube, Bilibili, …) tách video và âm thanh thành hai file riêng.
/// Nếu chỉ tải video thì file ra **không có tiếng** — đây là lỗi từng làm video
/// YouTube tải về bị mất âm thanh.
///
/// Container đích quyết định codec audio:
/// * `mp4/mov/m4v` → AAC (mp4 không chứa được opus/vorbis phổ biến).
/// * `webm` → Opus.
/// * `mkv/ts` → copy nguyên codec.
/// Video luôn `copy` — app không transcode hình.
public enum MediaMuxer {

    public enum MuxError: LocalizedError {
        case ffmpegNotFound
        case ffmpegFailed(code: Int32, message: String)
        case emptyOutput

        public var errorDescription: String? {
            switch self {
            case .ffmpegNotFound:
                return "Không tìm thấy ffmpeg để ghép video và âm thanh."
            case .ffmpegFailed(let code, let message):
                return "ffmpeg không ghép được (mã \(code)): \(message)"
            case .emptyOutput:
                return "File ghép ra rỗng."
            }
        }
    }

    /// Container phù hợp để chứa video + audio đã tách rời.
    ///
    /// Không phụ thuộc tên file người dùng nhập (có thể không có đuôi, hoặc đuôi
    /// sai) — chỉ dựa vào đuôi gợi ý của stream video.
    public static func preferredContainer(videoStreamExtension: String?) -> String {
        let ext = (videoStreamExtension ?? "").lowercased()
        if ext == "webm" { return "webm" }
        if ext == "mkv" { return "mkv" }
        if ["mp4", "m4v", "mov"].contains(ext) { return "mp4" }
        // Nguồn HLS/TS: mp4 là container an toàn nhất cho hầu hết codec phổ biến.
        return "mp4"
    }

    /// Ghép `video` và `audio` thành `output`.
    /// - Tham số: `output` phải có phần mở rộng container (`mp4`, `webm`, `mkv`).
    public static func mux(
        video: URL,
        audio: URL,
        output: URL,
        ffmpegPath: String? = nil
    ) throws {
        let ffmpeg = ffmpegPath ?? MediaURLResolver.findFfmpegBinary()
        guard let ffmpeg else { throw MuxError.ffmpegNotFound }
        // Đường dẫn được truyền vào có thể không tồn tại → lỗi rõ ràng thay vì
        // NSError mơ hồ của Process.run.
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else {
            throw MuxError.ffmpegNotFound
        }

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: output)
        try? fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

        let outputExt = output.pathExtension.lowercased()
        // Map tường minh: video từ input 0, audio từ input 1. Không để ffmpeg tự
        // chọn (có thể lấy audio từ chính file video nếu file đó có track lỗi).
        var args = [
            "-y", "-nostdin",
            "-i", video.path,
            "-i", audio.path,
            "-map", "0:v:0",
            "-map", "1:a:0",
            "-c:v", "copy"
        ]
        switch outputExt {
        case "mp4", "mov", "m4v":
            args += ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        case "webm":
            args += ["-c:a", "libopus", "-b:a", "160k"]
        default:
            args += ["-c:a", "copy"]
        }
        args.append(output.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8)?
                .split(separator: "\n")
                .last
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            try? fileManager.removeItem(at: output)
            throw MuxError.ffmpegFailed(code: proc.terminationStatus, message: message)
        }

        let size = (try? fileManager.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
        if size <= 0 {
            try? fileManager.removeItem(at: output)
            throw MuxError.emptyOutput
        }
    }
}
