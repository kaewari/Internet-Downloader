# Internet Downloader cho macOS (Desktop App & Browser Extension)

Trình tải xuống tốc độ cao dành riêng cho macOS, kế thừa mô hình kiến trúc kinh điển của **Internet Download Manager (IDM) trên Windows**:
- **Engine tải đa luồng phân đoạn (Multi-segment HTTP Range)**: Tự động chia file thành 8–16 kết nối song song, tối đa hóa băng thông đường truyền mạng.
- **Hỗ trợ Pause / Resume bền vững**: Lưu vết trạng thái từng byte range của mỗi chunk vào **SQLite** (`libsqlite3`), tiếp tục tải nguyên vẹn sau khi tạm dừng hoặc khởi động lại app.
- **Tải stream HLS (`.m3u8`)**: Tự động phân tích playlist, tải các segment video đồng thời và ghép nối thành file MP4/TS hoàn chỉnh — gồm cả nhánh audio tách rời (`EXT-X-MEDIA`) ghép đúng `AUDIO` group.
- **Cổng kiểm chứng tiếng (MediaIntegrity)**: mọi file video tải xong đều được `ffprobe` kiểm tra; thiếu audio thì tự ghép bổ sung từ trang gốc hoặc báo lỗi rõ ràng — không bao giờ lặng lẽ lưu video câm rồi báo "hoàn tất".
- **Desktop App thuần macOS (Swift & SwiftUI)**: Nhẹ, mượt mà, chuẩn Apple HIG, tích hợp **Segment Visualizer** trực quan theo dõi tiến độ từng luồng, Menu Bar Extra và Dock progress.
- **Chrome / Chromium Extension (Manifest V3)**:
  - Tự động bắt link tải file (Download Interception), thay thế trình tải mặc định của trình duyệt.
  - Thanh nổi bắt video (**Floating Media Sniffer Bar**) xuất hiện trực tiếp trên các player video web để click tải ngay lập tức.
- **Cầu nối Native Messaging Host**: Binary Swift siêu nhẹ giao tiếp với Extension qua Stdin/Stdout và Desktop App qua Unix Domain Socket nội bộ.

---

## Cấu trúc dự án

```text
Internet-Downloader/
├── Package.swift                    # Quản lý build và dependency bằng Swift Package Manager
├── Sources/
│   ├── DownloaderCore/              # Thư viện lõi dùng chung
│   │   ├── Models/                  # DownloadTask, DownloadSegment, IPCMessage
│   │   ├── Engine/                  # HTTPRangeDownloader, HLSDownloader, FileAssembler, DownloadManager
│   │   ├── Storage/                 # SQLiteStore (lưu trữ task, chunk, checkpoint)
│   │   └── IPC/                     # UnixDomainSocketServer & UnixDomainSocketClient
│   ├── NativeHost/                  # Binary CLI Chrome Native Messaging Host
│   │   └── main.swift
│   └── InternetDownloaderApp/        # Ứng dụng Desktop SwiftUI cho macOS
│       ├── InternetDownloaderApp.swift
│       ├── ViewModels/              # DownloadManagerViewModel
│       └── Views/                   # MainWindow, TaskRowView, SegmentVisualizerView, NewDownloadDialog
├── Tests/
│   └── DownloaderCoreTests/         # Toàn bộ Unit Tests và Integration Tests
├── Extension/                       # Browser Extension chuẩn Chromium Manifest V3
│   ├── manifest.json
│   ├── background.js                # Service Worker chặn tải & gửi Native Message
│   ├── content.js                   # Media Sniffer bắt video/audio & inject Floating Bar
│   ├── styles/sniffer.css           # Giao diện Floating Bar phong cách IDM
│   ├── popup/                       # Giao diện Popup cài đặt & kiểm tra kết nối
│   └── icons/                       # Icon kích thước 16, 48, 128
└── scripts/
    ├── install_native_host.sh       # Script đăng ký Native Host vào Chrome/Edge/Brave/Arc
    ├── run_tests.sh                 # Script chạy toàn bộ test & build tự động
    ├── verify_live_media_sources.py # Ma trận nền tảng (YouTube, TikTok…) qua pipeline app
    ├── verify_media_sources.py      # Bộ kiểm thử 100+ nguồn media thật qua pipeline app
    ├── refresh_media_sources.py     # Dò/làm mới/prune danh sách nguồn (chống thối link)
    ├── media_sources_100.json       # Danh sách nguồn media kiểm thử (nguồn chuẩn duy nhất)
    └── live_platform_sources.json   # Danh sách ca kiểm thử theo nền tảng
    └── archive/                     # Script deprecated đã nghỉ (download_and_verify_100_media, bootstrap_media_sources, run_100_sources_test)
```

---

## Hướng dẫn cài đặt & Khởi chạy

### 1. Yêu cầu môi trường
- macOS 13.0 (Ventura) trở lên.
- Xcode Command Line Tools hoặc Xcode (`swift` 5.9+).

### 2. Cài đặt Native Messaging Host cho Trình duyệt
Chạy script cài đặt để build binary và đăng ký manifest vào Chrome/Chromium/Edge/Brave/Arc:

```sh
./scripts/install_native_host.sh
```

### 3. Cài đặt Browser Extension vào Trình duyệt
1. Mở Google Chrome (hoặc Edge / Brave / Arc).
2. Truy cập địa chỉ: `chrome://extensions`.
3. Bật chế độ **Developer mode** ở góc trên bên phải.
4. Nhấn **Load unpacked** (Tải tiện ích đã giải nén).
5. Chọn thư mục `Extension` trong thư mục dự án này:
   ```text
   /Users/hoangson/Projects/Internet-Downloader/Extension
   ```

### 4. Khởi chạy Ứng dụng Desktop
Chạy ứng dụng trực tiếp từ terminal:

```sh
swift run InternetDownloader
```

Giao diện Desktop sẽ mở ra với Sidebar, danh sách tải, thanh IDM Segment Visualizer và Menu Bar Icon trên thanh tác vụ macOS.

---

## Kiểm thử tự động (Automated Verification)

Chạy toàn bộ bài test chất lượng cao:

```sh
./scripts/run_tests.sh
```

hoặc:

```sh
swift test
```

Bộ test gồm: Swift (`swift test` — segment, ghép file, SQLite migration, IPC Unix Domain Socket end-to-end, HLS master/audio-group, `MediaIntegrity`, `MediaMuxer`, yt-dlp split-file), Node (`node --test Tests/ExtensionTests/*.cjs`), Python validator và **HTTP fixture cục bộ** (`Tests/Fixtures/media_server.py` — HLS tách audio, HLS audio 404, MP4 video-only) chạy hoàn toàn offline. Kiểm tra đồng bộ phiên bản bằng `bash scripts/check_versions.sh`.

### Kiểm thử trực tiếp (live) — qua đúng engine của app

```sh
# Ma trận nền tảng: YouTube, TikTok, Vimeo, HLS… (app tự resolve → tải → ghép → ffprobe)
python3 scripts/verify_live_media_sources.py

# 100+ nguồn media thật (231 mục / 196 host / 52 nguồn NSFW) — tải head+tail, kiểm chứng magic byte + ffprobe
python3 scripts/verify_media_sources.py --tier quick
```

Cả hai bộ dùng chung `DownloaderCore/Testing/MediaSourceTestRunner.swift` — tức là
đi qua **đúng code của app** (`MediaURLResolver` + `HTTPRangeDownloader` + `FileTypeDetector`),
không phải tải bằng công cụ ngoài. Chi tiết: `TEST_READY.md`.
