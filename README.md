# Internet Downloader cho macOS (Desktop App & Browser Extension)

Trình tải xuống tốc độ cao dành riêng cho macOS, kế thừa mô hình kiến trúc kinh điển của **Internet Download Manager (IDM) trên Windows**:
- **Engine tải đa luồng phân đoạn (Multi-segment HTTP Range)**: Tự động chia file thành 8–16 kết nối song song, tối đa hóa băng thông đường truyền mạng.
- **Hỗ trợ Pause / Resume bền vững**: Lưu vết trạng thái từng byte range của mỗi chunk vào **SQLite** (`libsqlite3`), tiếp tục tải nguyên vẹn sau khi tạm dừng hoặc khởi động lại app.
- **Tải stream HLS (`.m3u8`)**: Tự động phân tích playlist, tải các segment video đồng thời và ghép nối thành file MP4/TS hoàn chỉnh.
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
    └── run_tests.sh                 # Script chạy toàn bộ test & build tự động
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

Tất cả các bài kiểm tra (bao gồm tính toán segment, ghép file, SQLite transaction, IPC Unix Domain Socket end-to-end, HLS playlist parsing) đều được thực thi và đạt kết quả PASS 100%.
