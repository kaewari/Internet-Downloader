import Foundation

/// Kiểm chứng luồng media của file đã tải bằng `ffprobe`.
///
/// Đây là "cổng" chống lỗi **video tải về không có tiếng**: trước đây app chỉ
/// kiểm kích thước rồi đánh dấu `completed`, nên file video-only (DASH/HLS tách
/// audio, hoặc yt-dlp thiếu ffmpeg) vẫn được báo thành công. Mọi đường tải phải
/// đi qua đây trước khi publish.
public struct MediaIntegrity: Sendable {

    /// Kết quả kiểm tra âm thanh của một file.
    public enum AudioVerdict: Equatable, Sendable {
        /// Chắc chắn có luồng audio.
        case hasAudio
        /// Chắc chắn không có luồng audio (đã probe được streams).
        case noAudio
        /// Không kiểm tra được (thiếu ffprobe, file hỏng, timeout…).
        case unverifiable
    }

    /// Danh sách loại stream đọc được từ file.
    public struct StreamReport: Sendable, Equatable {
        /// Giá trị `codec_type` của từng stream (video, audio, subtitle…).
        public let streams: [String]

        public init(streams: [String]) { self.streams = streams }

        public var hasVideo: Bool { streams.contains("video") }
        public var hasAudio: Bool { streams.contains("audio") }
        public var isEmpty: Bool { streams.isEmpty }
    }

    /// Đường dẫn `ffprobe`. Dò thêm các vị trí ngoài Homebrew mặc định và biến
    /// môi trường để máy dùng MacPorts/pipx vẫn kiểm chứng được.
    public static func ffprobeBinary(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let override = environment["IDM_FFPROBE_PATH"], FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let candidates = [
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
            "/opt/local/bin/ffprobe",
            "/usr/bin/ffprobe",
            (environment["HOME"] ?? NSHomeDirectory()) + "/.local/bin/ffprobe"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return whichBinary("ffprobe", environment: environment)
    }

    /// Tìm binary trong PATH bằng `which` (có timeout để không treo worker).
    static func whichBinary(_ name: String, environment: [String: String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [name]
        proc.environment = environment.merging(["PATH": environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]) { $1 }
        let result = MediaURLResolver.runProcessCapturingOutput(proc, seconds: 3)
        guard result.finished, proc.terminationStatus == 0,
              let text = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, FileManager.default.isExecutableFile(atPath: text) else {
            return nil
        }
        return text
    }

    /// Đọc `codec_type` của tất cả stream. `nil` = không kiểm tra được.
    public static func report(of file: URL, timeout: TimeInterval = 12) -> StreamReport? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard let ffprobe = ffprobeBinary() else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffprobe)
        proc.arguments = [
            "-v", "error",
            "-protocol_whitelist", "file,pipe",
            "-show_entries", "stream=codec_type",
            "-of", "csv=p=0",
            file.path
        ]
        let result = MediaURLResolver.runProcessCapturingOutput(proc, seconds: timeout)
        guard result.finished, proc.terminationStatus == 0 else { return nil }
        let text = String(data: result.stdout, encoding: .utf8) ?? ""
        let streams = text
            .split(separator: "\n")
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return StreamReport(streams: streams)
    }

    /// Kết luận nhanh về âm thanh.
    public static func audioVerdict(of file: URL) -> AudioVerdict {
        guard let report = report(of: file) else { return .unverifiable }
        return report.hasAudio ? .hasAudio : .noAudio
    }

    /// File có khả năng là container video (dựa trên đuôi) — dùng để quyết định
    /// có cần kiểm chứng audio hay không.
    public static func isLikelyVideoContainer(_ file: URL) -> Bool {
        let ext = file.pathExtension.lowercased()
        return ["mp4", "m4v", "mov", "mkv", "webm", "avi", "flv", "ts", "m3u8", "mpd", "m4s", "mpg", "mpeg"].contains(ext)
    }
}
