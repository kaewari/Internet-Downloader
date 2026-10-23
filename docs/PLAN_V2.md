# Plan v2 — sửa Telegram trong Internet Downloader

> **Snapshot cho 1.1.0/1.3.0** — tài liệu này là snapshot lịch sử tại thời điểm app 1.1.0 / extension 1.3.0 / browser protocol 2 (chốt 2026-10-10). Source hiện tại đã ở app 1.2.0 / extension 1.4.0; không dùng số phiên bản trong này để đối chiếu release hiện tại.

Plan được người dùng chốt ngày 2026-10-10. Phạm vi hiện tại là `/Users/hoangson/Projects/Internet-Downloader`, giữ app macOS và nút “Tải video này”. Lưu/Video_Downloader chỉ là nguồn tham khảo logic lựa chọn và canary, không là giao diện bàn giao cho bản sửa này.

## Mục tiêu

Chọn đúng attachment Telegram được phép lưu → app nhận job → Chrome thực hiện Save gốc → nối DownloadItem đúng → nhập byte có ACK → validation → lịch sử chính xác. Không chuyển `/k/stream`, Blob hoặc URL trang Telegram sang engine HTTP; không thêm credentials, debugger hoặc gọi Telegram manager nội bộ.

## Trạng thái mốc

| Mốc | Trạng thái | Bằng chứng/giới hạn |
|---|---|---|
| Chặn Blob/Telegram page/stream ở HTTP; bỏ chọn `media[0]`/page fallback | IMPLEMENTED + OFFLINE VERIFIED | Test đỏ trước sửa có ba assertion thất bại; test xanh sau sửa |
| Adapter chọn DOM, fingerprint, Save gốc Web A/K | IMPLEMENTED + OFFLINE VERIFIED | Viewer/message/permission/glyph/source-change; Telegram thật còn thiếu |
| Phản hồi thật từ app, taskId, handshake phiên bản | IMPLEMENTED + VERIFIED trong Chrome | Popup kết nối app 1.1.0/protocol 2; không báo thành công khi host/app từ chối |
| Browser `connectNative`, token job/session, 64 KiB/ACK, staging/hash/size, không ghi đè | IMPLEMENTED + OFFLINE VERIFIED | Native host thật chuyển file 32 MiB + 27 byte qua socket/ACK; bản nguồn giữ nguyên |
| Save đồng bộ, URL exact → downloadId → Chrome file → app | VERIFIED trong Chrome thật | Video tổng hợp 104495 byte; ba SHA256 khớp; decode độc lập đạt |
| Save bất đồng bộ/ambiguity → needs_confirmation sau 16 giây → USER_CONFIRMED | IMPLEMENTED + OFFLINE VERIFIED | Test timeout kể cả script chờ Save As; actor/native transfer test; ca Chrome async còn NOT VERIFIED |
| Hàng đợi chung hai job, cancel, tab/navigation/disconnect/restart, retry chọn lại | IMPLEMENTED + OFFLINE VERIFIED | Shared slots, cancellation, disconnect/restart; toàn bộ ma trận Chrome vòng đời còn NOT VERIFIED |
| Validation theo video/audio/image/file; metadata không chứa locator/auth | IMPLEMENTED + OFFLINE VERIFIED | ffprobe/decode, ảnh decode, file copy hash; test storage không token/session/media URL |
| HTTP redirect tối đa 10, scheme, bỏ auth đổi origin, từ chối HTML kỳ vọng media | IMPLEMENTED + OFFLINE VERIFIED | URLSession/server thật redirect, loop, thiếu Location, đổi origin, HTML khai báo/ẩn MIME |
| Build staging; bản trước/database/output/manifest được giữ; idle-only rollout | IMPLEMENTED + rollout đã kiểm tra | Installer riêng; ba row cũ và hai output cũ giữ checksum sau rollout đầu |
| Telegram Web K attachment thông thường + mục lỗi hiện tại; sau đó Web A | OFFLINE FIX ROUND 2 + LIVE PENDING | Đã sửa ưu tiên Save khả dụng trước no-forwards; chờ reload tab kiểm tra |
| Reload refinement cuối extension/tab | HOTFIX 2 IMPLEMENTED | Đã đóng gói dist 1.3.0 và test 15 Node pass; cần reload extension và F5 tab |
| Toàn bộ ma trận nghiệm thu | PARTIAL | Xem REVIEW_V2.md; sẵn sàng kiểm thử live trên Telegram Web |

## Kiến trúc đã triển khai

- App 1.1.0, extension 1.3.0, protocol browser 2; ID cũ không đổi.
- Selection/source/fingerprint nằm trong extension/session; job browser lưu `about:blank` như marker không thể retry HTTP, `browser_info` chứa sourceKind/method/proof/verification/phase/hash/validation/error. Không lưu media URL, locator, token, session ID, cookie hoặc header auth cho job browser.
- Native host đọc file regular của DownloadItem complete do background extension cung cấp trong capability đã cấp, chuyển chunk và chờ ACK. Page script không nhận đường dẫn local hoặc token.
- Save chỉ quan sát URL phát sinh đồng bộ trong chính thao tác được chọn. Các phiên Save được quan sát tuần tự để tránh lẫn thao tác; Chrome downloads đã nối vẫn tải song song, trong giới hạn hai slot chung. Async/album/menu không rõ một mục yêu cầu xác nhận file.
- MediaSource/Blob không được giả lập thành URL HTTPS. Telegram chỉ dùng native Save được UI cho phép; generic Blob không có Save trả thông báo cần đường trình duyệt.

## Ca phải chạy tiếp trước khi đóng toàn bộ plan

Telegram K và A: video/voice/ảnh/sticker/document, một mục và album; nguồn đổi/mất quyền; cùng tên file/hai tab/download không liên quan; Save async/Save As/cancel/tab close/logout/restart. File: hết dung lượng, lỗi đọc/copy, very large file với đo peak memory, trùng tên và sai hash. Ca chưa có evidence phải giữ NOT VERIFIED, ghi đúng giai đoạn. Report riêng tư chỉ ghi metadata cần thiết, che locator/chat/tên nội dung.

## Điều kiện hoàn thành

Không có HTTP job Telegram/Blob sai; đúng mục được chọn; file Chrome và app byte/hash phù hợp; thông báo/lịch sử đúng từng giai đoạn. Chỉ đóng toàn bộ plan khi Telegram thật K và A đạt ca đã chọn cùng các ca nghiệm thu bắt buộc, không từ fixture suy ra hỗ trợ toàn nền tảng.
