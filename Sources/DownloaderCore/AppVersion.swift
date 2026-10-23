import Foundation

/// Nguồn duy nhất cho phiên bản app / protocol / extension.
///
/// Trước đây các chuỗi này được hardcode ở 6 nơi (app, native host, extension,
/// script build, script install) nên dễ lệch. Lệch phiên bản khiến handshake
/// browser → app fail với thông báo mơ hồ, còn người dùng thì thấy "bấm nút
/// tải mà không có gì xảy ra". Mọi nơi phải đọc từ đây (và bản mirror trong
/// `Extension/browser-transfer.js` — xem `scripts/check_versions.sh`).
public enum AppVersion: Sendable {
    /// Phiên bản giao thức IPC giữa extension/native host và app.
    public static let protocolVersion = 2

    /// `CFBundleShortVersionString` của app; cũng là phiên bản app mà
    /// extension/native host yêu cầu để đảm bảo hai bên cùng bản.
    public static let appVersion = "1.2.0"

    /// Phiên bản extension (manifest.json). Mirror để script kiểm tra chéo.
    public static let extensionVersion = "1.4.0"

    public static let nativeHostName = "com.internetdownloader.host"
    public static let bundleIdentifier = "com.hoangson.InternetDownloader"
    public static let appExecutableName = "InternetDownloader"
    public static let extensionAllowedOrigin = "chrome-extension://nljinpcahdihnlhidjdacnhlchlpblnk/"
}
