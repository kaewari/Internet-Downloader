import Foundation
import DownloaderCore

/// Helper dùng chung cho App layer (C-F12, C-F16).
/// Gom `fileExt`/`fileIcon` từng copy ở MainWindow + ViewModel + TaskRowView + dialogs
/// về một chỗ, kèm ByteCountFormatter cache (tránh tạo formatter mỗi row/tick).
public enum FileTypeHelper {
    // MARK: - Extension

    public static func fileExtension(of filename: String) -> String {
        URL(fileURLWithPath: filename).pathExtension.lowercased()
    }

    // MARK: - Category (canonical sets, dùng cho filter + count 1-pass)

    public static let videoExtensions: Set<String> = ["mp4", "mkv", "mov", "avi", "webm", "ts", "m3u8", "m4v", "qt", "flv", "mpd", "m4s"]
    public static let audioExtensions: Set<String> = ["mp3", "m4a", "flac", "wav", "aac", "ogg", "opus", "wma"]
    public static let compressedExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz", "zst"]
    public static let programExtensions: Set<String> = ["dmg", "pkg", "iso", "app", "exe", "msi", "deb", "rpm", "appimage", "apk", "xar"]
    public static let documentExtensions: Set<String> = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "csv", "epub", "rtf", "json", "xml"]
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "svg", "bmp", "heic", "avif", "tif", "tiff"]

    /// Trả về category kiểu-file của filename, nil nếu không thuộc nhóm media nào.
    public static func category(for filename: String) -> DownloadCategory? {
        let ext = fileExtension(of: filename)
        guard !ext.isEmpty else { return nil }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if compressedExtensions.contains(ext) { return .compressed }
        if programExtensions.contains(ext) { return .programs }
        if documentExtensions.contains(ext) { return .documents }
        if imageExtensions.contains(ext) { return .images }
        return nil
    }

    // MARK: - Icon

    public static func iconName(for filename: String) -> String {
        let ext = fileExtension(of: filename)
        if videoExtensions.contains(ext) { return "film" }
        if audioExtensions.contains(ext) { return "music.note" }
        if compressedExtensions.contains(ext) { return "doc.zipper" }
        if programExtensions.contains(ext) { return "shippingbox" }
        if documentExtensions.contains(ext) { return "doc.richtext" }
        if imageExtensions.contains(ext) { return "photo" }
        return "doc"
    }

    // MARK: - Byte formatting (formatter cache, C-F16)

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private static let speedFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    /// Gọi trên MainActor (UI). ByteCountFormatter không thread-safe nên không
    /// dùng chung từ background — phần nặng đã tách sang Task.detached.
    public static func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        return byteFormatter.string(fromByteCount: bytes)
    }

    public static func formatSpeed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "0 B/s" }
        return speedFormatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    // MARK: - Filename validation (C-F9)

    /// Trả về message lỗi nếu filename không hợp lệ, nil nếu OK.
    public static func filenameError(for name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Tên file không được để trống." }
        if trimmed == "." || trimmed == ".." { return "Tên file không hợp lệ." }
        if trimmed.contains("/") || trimmed.contains("\0") {
            return "Tên file không được chứa ký tự “/”."
        }
        if trimmed.contains(":") {
            return "Tên file không được chứa ký tự “:”."
        }
        return nil
    }
}
