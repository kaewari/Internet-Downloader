import XCTest
@testable import DownloaderCore

/// Regression cho lỗi "video tải về mất tiếng".
///
/// Nguyên nhân gốc: `resolveWithYtDlp` dùng `yt-dlp -g` và chỉ giữ **URL đầu tiên**.
/// Với nguồn DASH (YouTube, Bilibili…) yt-dlp trả **hai** URL — video-only và
/// audio-only — nên file tải về chỉ có hình, không có tiếng, nhưng task vẫn báo
/// "completed". Không có test nào bắt được lỗi này vì harness cũ dùng chính
/// `yt-dlp` để tải (nên tự động có cả hai).
final class YtDlpFormatResolutionTests: XCTestCase {

    // MARK: - Fixtures

    /// JSON thật của `yt-dlp -J` cho YouTube: 2 format tách biệt.
    private let youTubeDashJSON = """
    {
      "id": "jNQXAC9IVRw",
      "title": "Me at the zoo",
      "ext": "webm",
      "requested_formats": [
        {
          "format_id": "395",
          "url": "https://rr4---sn.example.googlevideo.com/videoplayback?itag=395&mime=video%2Fmp4",
          "ext": "mp4",
          "vcodec": "av01.0.00M.08.0.110.05.01.06.0",
          "acodec": "none",
          "height": 1080,
          "tbr": 1200.5,
          "protocol": "https"
        },
        {
          "format_id": "251",
          "url": "https://rr4---sn.example.googlevideo.com/videoplayback?itag=251&mime=audio%2Fwebm",
          "ext": "webm",
          "vcodec": "none",
          "acodec": "opus",
          "abr": 129.5,
          "tbr": 132.0,
          "protocol": "https"
        }
      ]
    }
    """

    /// Nguồn có sẵn format hợp nhất (video + audio trong một file).
    private let combinedJSON = """
    {
      "title": "Combined clip",
      "ext": "mp4",
      "requested_formats": [
        {
          "format_id": "18",
          "url": "https://cdn.example.com/combined.mp4",
          "ext": "mp4",
          "vcodec": "avc1.4d401f",
          "acodec": "mp4a.40.2",
          "height": 360,
          "tbr": 500.0,
          "protocol": "https"
        }
      ]
    }
    """

    /// Không có `requested_formats` → phải tự chọn từ `formats[]`.
    private let formatsFallbackJSON = """
    {
      "title": "Fallback clip",
      "ext": "mp4",
      "formats": [
        {
          "format_id": "137",
          "url": "https://cdn.example.com/video-1080.mp4",
          "ext": "mp4",
          "vcodec": "avc1.640028",
          "acodec": "none",
          "height": 1080,
          "tbr": 3000.0,
          "protocol": "https"
        },
        {
          "format_id": "136",
          "url": "https://cdn.example.com/video-720.mp4",
          "ext": "mp4",
          "vcodec": "avc1.4d401f",
          "acodec": "none",
          "height": 720,
          "tbr": 1500.0,
          "protocol": "https"
        },
        {
          "format_id": "140",
          "url": "https://cdn.example.com/audio-128.m4a",
          "ext": "m4a",
          "vcodec": "none",
          "acodec": "mp4a.40.2",
          "abr": 128.0,
          "protocol": "https"
        }
      ]
    }
    """

    private func selection(_ json: String) -> YtDlpSelection? {
        MediaURLResolver.selectStreams(fromYtDlpJSON: Data(json.utf8))
    }

    // MARK: - Tests

    /// Lỗi gốc: nguồn DASH phải trả cả video và audio để ghép.
    func testDashSourceYieldsBothVideoAndAudioStreams() throws {
        let result = try XCTUnwrap(selection(youTubeDashJSON))
        XCTAssertEqual(result.streams.count, 2, "Phải giữ cả URL video-only và audio-only")
        XCTAssertTrue(result.requiresMux, "Nguồn DASH không có format hợp nhất → phải ghép")
        XCTAssertEqual(result.streams[0].role, .video)
        XCTAssertEqual(result.streams[1].role, .audio)
        XCTAssertEqual(result.streams[0].formatID, "395")
        XCTAssertEqual(result.streams[1].formatID, "251")
    }

    /// Format hợp nhất → không ghép, tải thẳng một file.
    func testCombinedFormatNeedsNoMux() throws {
        let result = try XCTUnwrap(selection(combinedJSON))
        XCTAssertEqual(result.streams.count, 1)
        XCTAssertFalse(result.requiresMux)
        XCTAssertTrue(result.streams[0].includesAudio)
        XCTAssertEqual(result.streams[0].role, .video)
    }

    /// Không có `requested_formats` → chọn video cao nhất + audio tốt nhất.
    func testFallsBackToFormatsArrayWhenRequestedFormatsMissing() throws {
        let result = try XCTUnwrap(selection(formatsFallbackJSON))
        XCTAssertEqual(result.streams.count, 2)
        XCTAssertTrue(result.requiresMux)
        XCTAssertEqual(result.streams[0].formatID, "137", "Chọn video cao nhất (1080p)")
        XCTAssertEqual(result.streams[1].formatID, "140", "Chọn audio tốt nhất")
    }

    /// Chỉ có video (không có audio) → không ghép, tải thẳng.
    func testVideoOnlySourceDoesNotRequestMux() throws {
        let json = """
        { "title": "Silent clip", "requested_formats": [
          { "format_id": "137", "url": "https://cdn.example.com/v.mp4", "vcodec": "avc1", "acodec": "none", "height": 720, "protocol": "https" }
        ] }
        """
        let result = try XCTUnwrap(selection(json))
        XCTAssertEqual(result.streams.count, 1)
        XCTAssertFalse(result.requiresMux)
    }

    /// JSON hỏng / rỗng → nil (không crash).
    func testInvalidJSONReturnsNil() {
        XCTAssertNil(MediaURLResolver.selectStreams(fromYtDlpJSON: Data("not json".utf8)))
        XCTAssertNil(MediaURLResolver.selectStreams(fromYtDlpJSON: Data("{}".utf8)))
    }

    /// Format không phải http(s) (ví dụ m3u8 native) vẫn được chấp nhận,
    /// nhưng format không có URL tải trực tiếp thì bị loại.
    func testFormatsWithoutDirectURLAreSkipped() throws {
        let json = """
        { "title": "Mixed", "requested_formats": [
          { "format_id": "hls", "protocol": "m3u8", "vcodec": "none", "acodec": "none" },
          { "format_id": "v", "url": "https://cdn.example.com/v.mp4", "vcodec": "avc1", "acodec": "none", "protocol": "https" }
        ] }
        """
        let result = try XCTUnwrap(selection(json))
        XCTAssertEqual(result.streams.count, 1)
        XCTAssertEqual(result.streams[0].formatID, "v")
    }

    // MARK: - ResolvedMedia

    /// `ResolvedMedia.requiresMux` phải phản ánh đúng danh sách stream.
    func testResolvedMediaRequiresMuxReflectsStreams() {
        let videoURL = URL(string: "https://cdn.example.com/v.mp4")!
        let audioURL = URL(string: "https://cdn.example.com/a.m4a")!

        let dash = ResolvedMedia(
            directURL: videoURL,
            mediaStreams: [
                ResolvedStream(url: videoURL, role: .video, includesAudio: false),
                ResolvedStream(url: audioURL, role: .audio)
            ]
        )
        XCTAssertTrue(dash.requiresMux)
        XCTAssertNotNil(dash.videoStream)
        XCTAssertNotNil(dash.audioStream)

        let combined = ResolvedMedia(
            directURL: videoURL,
            mediaStreams: [ResolvedStream(url: videoURL, role: .video, includesAudio: true)]
        )
        XCTAssertFalse(combined.requiresMux)

        let direct = ResolvedMedia(directURL: videoURL)
        XCTAssertFalse(direct.requiresMux)
    }
}
