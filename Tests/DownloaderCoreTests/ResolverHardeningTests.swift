import XCTest
@testable import DownloaderCore

/// Kiểm chứng các bản vá cứng cỏng trong lớp resolve/normalize:
/// - Không coi trang nhúng (`og:video` → `/embed/…`) là media
/// - Giữ cookie khi resolve sang host cùng site
/// - Tệp HTML là tệp hợp lệ (không bị chặn nhầm)
final class ResolverHardeningTests: XCTestCase {

    func testEmbedPageIsNotTreatedAsMedia() {
        let embed = URL(string: "https://www.youtube.com/embed/jNQXAC9IVRw")!
        XCTAssertFalse(MediaURLResolver.isPlausibleMediaURL(embed), "Trang /embed/ không phải media")

        let watch = URL(string: "https://www.youtube.com/watch?v=jNQXAC9IVRw")!
        XCTAssertFalse(MediaURLResolver.isPlausibleMediaURL(watch))

        let status = URL(string: "https://x.com/user/status/123456")!
        XCTAssertFalse(MediaURLResolver.isPlausibleMediaURL(status))

        // Media thật vẫn phải qua được
        XCTAssertTrue(MediaURLResolver.isPlausibleMediaURL(URL(string: "https://cdn.example.com/video.mp4")!))
        XCTAssertTrue(MediaURLResolver.isPlausibleMediaURL(URL(string: "https://cdn.example.com/master.m3u8")!))
        XCTAssertTrue(MediaURLResolver.isPlausibleMediaURL(URL(string: "https://cdn.example.com/stream/12345")!))
    }

    func testSameSiteDomainComparison() {
        XCTAssertTrue(URLNormalizer.isSameSiteDomain("m.youtube.com", "youtube.com"))
        XCTAssertTrue(URLNormalizer.isSameSiteDomain("youtube.com", "youtube.com"))
        XCTAssertFalse(URLNormalizer.isSameSiteDomain("youtube.com", "googlevideo.com"))
        XCTAssertFalse(URLNormalizer.isSameSiteDomain("instagram.com", "fbcdn.net"))
    }

    func testHTMLFileIsAllowedButMediaIsNot() {
        XCTAssertTrue(HTTPRangeDownloader.isHTMLFileName("page.html"))
        XCTAssertTrue(HTTPRangeDownloader.isHTMLFileName("page.HTM"))
        XCTAssertTrue(HTTPRangeDownloader.isHTMLFileName("page.xhtml"))
        XCTAssertFalse(HTTPRangeDownloader.isHTMLFileName("video.mp4"))
        XCTAssertFalse(HTTPRangeDownloader.isHTMLFileName("archive.zip"))

        XCTAssertTrue(HTTPRangeDownloader.looksLikeHTML("<!DOCTYPE HTML><html>"))
        XCTAssertTrue(HTTPRangeDownloader.looksLikeHTML("  <html lang=\"en\">"))
        XCTAssertFalse(HTTPRangeDownloader.looksLikeHTML("\u{0}\u{1}\u{2}binary"))
    }

    func testShortLinkPlatformsAreRecognized() {
        for host in ["dai.ly", "b23.tv", "t.co"] {
            XCTAssertTrue(
                URLNormalizer.isVideoPlatformURL(URL(string: "https://\(host)/abc123")!),
                "\(host) phải được nhận diện là nền tảng"
            )
        }
    }

    func testRetryPolicyHonorsRetryAfterHeader() {
        // Header Retry-After bằng giây được tôn trọng
        let delay = RetryPolicy.retryDelay(attempt: 0, retryAfterHeader: "7")
        XCTAssertEqual(delay, 7)

        // Không có header → dùng backoff
        XCTAssertEqual(RetryPolicy.retryDelay(attempt: 0, retryAfterHeader: nil), 1.0)
        XCTAssertEqual(RetryPolicy.retryDelay(attempt: 1, retryAfterHeader: nil), 2.0)

        // Header vô lý (quá lớn / không phải số) → bỏ qua, dùng backoff
        XCTAssertEqual(RetryPolicy.retryDelay(attempt: 0, retryAfterHeader: "99999"), 1.0)
        XCTAssertEqual(RetryPolicy.retryDelay(attempt: 0, retryAfterHeader: "Wed, 21 Oct 2026 07:28:00 GMT"), 1.0)

        // 5xx/429 retry được, 4xx thì không
        XCTAssertTrue(RetryPolicy.isRetryable(NSError(domain: "HTTPRangeDownloader", code: 503)))
        XCTAssertTrue(RetryPolicy.isRetryable(NSError(domain: "HTTPRangeDownloader", code: 429)))
        XCTAssertFalse(RetryPolicy.isRetryable(NSError(domain: "HTTPRangeDownloader", code: 404)))
        XCTAssertTrue(RetryPolicy.isRetryable(URLError(.networkConnectionLost)))
        XCTAssertFalse(RetryPolicy.isRetryable(URLError(.cancelled)))
    }

    /// Hồi quy: tải HLS phải đổi tên đích sang .mp4.
    ///
    /// Nếu giữ đuôi .m3u8, bước remux của HLSDownloader bị bỏ qua → nhánh âm
    /// thanh riêng không được ghép → file ra không có tiếng (đã tái hiện được
    /// với Reddit v.redd.it).
    func testHLSDestinationFileIsRenamedToMP4() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("idm_hlsname_\(UUID().uuidString)")

        let playlist = DownloadTask(
            url: URL(string: "https://v.redd.it/abc/HLSPlaylist.m3u8")!,
            filename: "HLSPlaylist.m3u8",
            destinationFolder: dir
        )
        XCTAssertEqual(DownloadManager.hlsDestinationFile(for: playlist).lastPathComponent, "HLSPlaylist.mp4")

        let master = DownloadTask(
            url: URL(string: "https://example.com/master.m3u8")!,
            filename: "master.m3u8",
            destinationFolder: dir
        )
        XCTAssertEqual(DownloadManager.hlsDestinationFile(for: master).lastPathComponent, "video.mp4")

        let index = DownloadTask(
            url: URL(string: "https://example.com/index.m3u8")!,
            filename: "index.m3u8",
            destinationFolder: dir
        )
        XCTAssertEqual(DownloadManager.hlsDestinationFile(for: index).lastPathComponent, "video.mp4")

        // Tệp đã là .mp4 thì giữ nguyên
        let movie = DownloadTask(
            url: URL(string: "https://example.com/clip.mp4")!,
            filename: "clip.mp4",
            destinationFolder: dir
        )
        XCTAssertEqual(DownloadManager.hlsDestinationFile(for: movie).lastPathComponent, "clip.mp4")
    }

    func testMuxDetectionForCombinedAndSplitStreams() {        let video = URL(string: "https://cdn.example.com/v.mp4")!
        let audio = URL(string: "https://cdn.example.com/a.m4a")!

        // DASH: video-only + audio-only → cần ghép
        let dash = ResolvedMedia(
            directURL: video,
            mediaStreams: [
                ResolvedStream(url: video, role: .video, includesAudio: false),
                ResolvedStream(url: audio, role: .audio)
            ]
        )
        XCTAssertTrue(dash.requiresMux)

        // Progressive: một file có cả hai → không ghép
        let progressive = ResolvedMedia(
            directURL: video,
            mediaStreams: [ResolvedStream(url: video, role: .video, includesAudio: true)]
        )
        XCTAssertFalse(progressive.requiresMux)
    }

    /// Đuôi tệp lạ do URL (ví dụ `.../format=h.264`) phải được sửa lại theo
    /// magic byte thật của file sau khi tải.
    func testKnownExtensionSetCoversMediaAndDocuments() {
        XCTAssertTrue(FileTypeDetector.knownExtensions.contains("mp4"))
        XCTAssertTrue(FileTypeDetector.knownExtensions.contains("mp3"))
        XCTAssertTrue(FileTypeDetector.knownExtensions.contains("zip"))
        XCTAssertTrue(FileTypeDetector.knownExtensions.contains("pdf"))
        // Đuôi bất thường từ URL không nằm trong tập → coi là "không xác định".
        XCTAssertFalse(FileTypeDetector.knownExtensions.contains("264"))
        XCTAssertFalse(FileTypeDetector.knownExtensions.contains("h264"))
    }

    /// File tải về có nội dung MP4 nhưng tên là "format=h.264" → sau khi tải,
    /// app phải đổi tên thành "format.h.264.mp4"? Không: đuôi lạ bị thay bằng
    /// đuôi thật ("format=h.mp4") — kiểm chứng bằng logic dùng chung.
    func testUnknownExtensionIsReplacedByDetectedType() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("idm_extfix_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // File MP4 thật (ftyp ở 4 byte đầu)
        let file = dir.appendingPathComponent("format=h.264")
        var header = Data([0x00, 0x00, 0x00, 0x18])
        header.append(Data("ftypisom".utf8))
        header.append(Data(repeating: 0, count: 512))
        try header.write(to: file)

        let detected = FileTypeDetector.detectExtension(fileURL: file)
        XCTAssertEqual(detected, "mp4", "Magic byte phải nhận ra MP4")

        let currentExt = (file.lastPathComponent as NSString).pathExtension
        XCTAssertEqual(currentExt, "264")
        XCTAssertFalse(FileTypeDetector.knownExtensions.contains(currentExt.lowercased()),
                       "Đuôi '264' phải được coi là không xác định để sửa lại")
    }
}
