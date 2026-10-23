import XCTest
import CryptoKit
@testable import DownloaderCore

/// Kiểm chứng thực sự việc ghép video + âm thanh bằng ffmpeg.
///
/// Đây là bước kiểm chứng cho lỗi "video tải về mất tiếng": sau khi ghép, file
/// cuối phải có **cả** luồng video và luồng âm thanh (kiểm bằng ffprobe).
final class MuxIntegrationTests: XCTestCase {

    private func ffmpegPath() -> String? {
        MediaURLResolver.findFfmpegBinary()
    }

    private func ffprobePath() -> String? {
        for candidate in ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Tạo một file video (không tiếng) và một file audio bằng ffmpeg.
    private func makeMediaParts(in dir: URL) throws -> (video: URL, audio: URL)? {
        guard let ffmpeg = ffmpegPath() else { return nil }

        let video = dir.appendingPathComponent("video.mp4")
        let audio = dir.appendingPathComponent("audio.m4a")

        func run(_ args: [String]) throws {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffmpeg)
            proc.arguments = args
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            try proc.run()
            proc.waitUntilExit()
            XCTAssertEqual(proc.terminationStatus, 0, "ffmpeg thất bại: \(args.joined(separator: " "))")
        }

        // video 1 giây màu đỏ, không có âm thanh
        try run(["-y", "-f", "lavfi", "-i", "color=c=red:s=320x240:d=1", "-c:v", "libx264", "-pix_fmt", "yuv420p", video.path])
        // audio 1 giây 440Hz
        try run(["-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-c:a", "aac", audio.path])

        return (video, audio)
    }

    /// Kiểm tra file có cả luồng video và luồng audio không (dùng ffprobe).
    private func streamKinds(of file: URL) throws -> Set<String> {
        guard let ffprobe = ffprobePath() else {
            throw XCTSkip("Thiếu ffprobe để kiểm chứng stream")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffprobe)
        proc.arguments = ["-v", "error", "-show_entries", "stream=codec_type", "-of", "csv=p=0", file.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    /// Ghép video-only + audio-only → file cuối phải có CẢ video lẫn audio.
    func testMuxProducesFileWithBothVideoAndAudioStreams() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("idm_mux_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        guard let parts = try makeMediaParts(in: dir) else {
            throw XCTSkip("Thiếu ffmpeg để tạo media test")
        }

        let output = dir.appendingPathComponent("merged.mp4")
        try MediaMuxer.mux(video: parts.video, audio: parts.audio, output: output)

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(size, 0)

        let kinds = try streamKinds(of: output)
        XCTAssertTrue(kinds.contains("video"), "File ghép phải có luồng video — thực tế: \(kinds)")
        XCTAssertTrue(kinds.contains("audio"), "File ghép phải có luồng audio — thực tế: \(kinds)")
    }

    /// File video-only (chưa ghép) chỉ có luồng video → đây chính là lỗi "mất tiếng".
    func testVideoOnlyPartHasNoAudioStream() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("idm_muxv_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        guard let parts = try makeMediaParts(in: dir) else {
            throw XCTSkip("Thiếu ffmpeg để tạo media test")
        }

        let kinds = try streamKinds(of: parts.video)
        XCTAssertTrue(kinds.contains("video"))
        XCTAssertFalse(kinds.contains("audio"), "Video-only đúng là không có audio — nếu có thì test ghép không có ý nghĩa")
    }

    /// Không có ffmpeg → lỗi rõ ràng thay vì crash.
    func testMuxWithoutFfmpegThrowsClearError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("idm_muxf_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let video = dir.appendingPathComponent("v.mp4")
        let audio = dir.appendingPathComponent("a.m4a")
        try Data([0]).write(to: video)
        try Data([0]).write(to: audio)

        let output = dir.appendingPathComponent("out.mp4")
        XCTAssertThrowsError(try MediaMuxer.mux(video: video, audio: audio, output: output, ffmpegPath: "/nonexistent/ffmpeg")) { error in
            guard case MediaMuxer.MuxError.ffmpegNotFound = error else {
                XCTFail("Kỳ vọng lỗi ffmpegNotFound, nhận: \(error)")
                return
            }
        }
    }
}
