# Internet Downloader 1.1.0 — tải qua Chrome

Dùng Internet Downloader macOS hiện tại cùng extension Internet Downloader Integration Module 1.3.0. Native host/app bắt tay browser protocol 2. ID giữ nguyên: `nljinpcahdihnlhidjdacnhlchlpblnk`. Bản sửa này không thêm quyền debugger.

## Dùng Telegram Web

1. Trong `chrome://extensions`, mở extension Internet Downloader Integration Module và bấm **Reload**. Extension đang cài trên máy này đọc từ `/Users/hoangson/Projects/Internet-Downloader/Extension`. Bản ZIP bàn giao chứa cùng source trong `dist/Extension`.
2. Reload tab Telegram để thay content script cũ, rồi mở lại đúng attachment cần lưu. Không tự tìm/duyệt lịch sử các chat khác.
3. Bấm **Tải video này** trên video, hoặc mở popup extension → **Chọn attachment / Save trong tab** → chọn rõ mục. Ảnh/audio/file có nút Save cũng dùng popup này. Nếu có nhiều mục, chọn từng mục; không suy ra toàn bộ album từ nút Download của tin nhắn.
4. Extension chỉ kích hoạt Download/Save gốc của website. `website_save_unavailable` chỉ dành cho dấu hiệu hạn chế `no-forwards` trên mục/viewer đã chọn. Không tìm thấy nút dùng `website_save_not_found`; nút đang disabled/loading dùng `website_save_not_ready`; media ngoài viewer chưa có thao tác Save riêng dùng `attachment_viewer_required`. Mở attachment trong viewer và chờ nút sẵn sàng để thử lại. Video phát được chưa chứng minh website cho phép lưu.
5. Theo dõi **App đã nhận tác vụ → Đang lưu qua Chrome → Đang nhập/kiểm tra → Hoàn tất**. Giữ tab và phiên đăng nhập trong lúc tải. Có thể cần thao tác **Save As** của Chrome; chọn tên/thư mục rồi bấm Save. Bản Chrome được giữ, app nhập một bản riêng vào thư mục đích hiện tại.
6. Nếu sau 16 giây chưa nối được một DownloadItem mới với URL tạo từ đúng Save, app chuyển **Cần xác nhận file trong Chrome**. Mở/reopen popup, chọn đúng file Chrome **đã hoàn tất**, rồi bấm **Xác nhận đây là file đã chọn**. Trường hợp này ghi `USER_CONFIRMED`; tên file/thời gian không trở thành bằng chứng tự động.
7. **Hủy phiên tải** trong popup hoặc hủy trong app. Nếu đã nối được downloadId, extension cũng hủy download Chrome đang chạy. File Chrome chưa chứng minh liên kết phải do người dùng kiểm soát trong Chrome; app không đoán file nào để hủy. Sau mất tab/điều hướng/restart, chọn lại attachment; không retry endpoint stream cũ.

`VERIFIED` chứng minh liên kết tự động đã đạt yêu cầu và bản file website lưu đã qua validation tương ứng. `USER_CONFIRMED` dùng lựa chọn file của người dùng. SHA256 chứng minh bản sao khớp bản Chrome đã lưu; không chứng minh đây là byte trước khi upload hoặc mọi variant của Telegram.

## Build và cập nhật

Chạy từ `/Users/hoangson/Projects/Internet-Downloader`:

```sh
bash scripts/run_tests.sh
idm_release_dir="$PWD/.runtime/releases/$(date +%Y%m%d-%H%M%S)"
IDM_BUILD_DIR="$idm_release_dir" bash scripts/build_app.sh
```

Build chỉ tạo staging, kiểm tra chữ ký và đóng gói extension; không xóa `dist`, không tự sửa native-host manifest. Sau khi không còn job pending/active/needs_confirmation, quit app và cài staging:

```sh
python3 scripts/install_release.py --stage "$idm_release_dir"
```

Installer kiểm tra version/ID/signature, snapshot SQLite, checksum output, manifest và giữ bundle trước. Host Chrome trỏ đến helper trong đúng `dist/Internet Downloader.app`; helper chỉ mở bundle chứa nó. Mở bundle đó và Reload extension/tab. Popup phải báo kết nối đã xác minh; app/extension cũ không được coi là tương thích protocol 2.

## Rollback

Không rollback khi còn job hoạt động. Quit app; chọn snapshot `.runtime/rollout-*` của lần cài tương ứng. Giữ bản hiện tại riêng, phục hồi app/Extension/ZIP và `native-host-before.json`, rồi Reload extension và mở bundle trước. SQLite được migration thêm cột nullable; chỉ phục hồi `before.sqlite3` khi cần quay toàn bộ lịch sử về snapshot, giữ database hiện tại riêng trước. Không phục hồi database cũ qua các job/file mới chưa được snapshot.

Snapshot đầu của lượt sửa ở `.runtime/telegram-v2/rollout` giữ `Internet Downloader.previous.app`, database, manifest và checksum. Snapshot installer tiếp theo giữ tên app nguyên gốc.

## Nghiệm thu fixture Chrome

```sh
python3 scripts/browser_fixture.py
```

Mở `http://127.0.0.1:8810/` trong Chrome đã cài extension. `/?async` tạo Save bất đồng bộ; `/?document` dùng file tổng hợp; `/?async&document` kết hợp hai ca. Chọn Save qua popup, không dùng nút tải HTTP thông thường để thay cho ca browser. Đối chiếu file nguồn, bản Chrome và bản app với `.runtime/browser-fixture/expected.json`. Fixture và test offline không thay thế nghiệm thu Telegram Web A/K đang đăng nhập.

Cần FFmpeg/ffprobe tại `/opt/homebrew/bin` hoặc `/usr/local/bin` cho validation media; ảnh dùng ImageIO. Tài liệu chỉ kiểm tra transport/size/hash, không tự mở hoặc giải nén.
