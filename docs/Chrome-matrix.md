# Chrome acceptance matrix — manual checklist (NOT VERIFIED)

> **Trạng thái: NOT VERIFIED** — các ca dưới đây yêu cầu Chrome thật + Telegram
> đăng nhập và **không** thuộc gate offline (`scripts/run_tests.sh`). Offline
> fixture chỉ xác minh logic đã ghi, không nâng tier những ca này.
> (Nguồn: `docs/PLAN_V2.md` §"Ca phải chạy tiếp", `docs/REVIEW_V2.md` §NOT VERIFIED,
> `docs/AUDIT_REPORT.md` §1.5 E-F2/E-F3 + §5, `docs/IDEAS_BACKLOG.md` E-I1.)

## Cách ghi kết quả

Mỗi ca: `PASS | FAIL | SKIP + evidence` (đường dẫn log/file, byte/hash khi có).
Không suy từ fixture ra hỗ trợ toàn nền tảng. Report riêng tư chỉ ghi metadata
cần thiết, che locator/chat/tên nội dung.

## 1. Two-tab isolation (2 tab đồng thời)

- [ ] Mở 2 tab Telegram khác nhau, chọn Save ở cả 2 tab gần như đồng thời →
      2 job browser riêng, đúng `sessionId`/`token` mỗi tab, không lẫn DownloadItem.
- [ ] Cùng tên file ở 2 tab → app công bố tên không ghi đè, giữ cả 2 bản.
- [ ] Download không liên quan (ngoài Telegram) chạy cùng lúc → không bị nhận
      nhầm vào job browser (`selectionProof = native_action_exact_url`).

## 2. Async Save / Save As

- [ ] Save bất đồng bộ (menu Save As hiện > 16s) → job chuyển
      `needs_confirmation`, chọn file complete rõ ràng → ghi `USER_CONFIRMED`.
- [ ] Cancel dialog Save As → job fail rõ ràng, không kẹt `needs_confirmation`.
- [ ] Disconnect/restart giữa chừng → selection mất hiệu lực, retry yêu cầu chọn lại.

## 3. Album (nhiều mục)

- [ ] Album nhiều ảnh/video: chỉ đúng mục được chọn mới tạo job; mục còn lại
      không sinh job ma.
- [ ] Voice / photo / sticker / document (Telegram K rồi A) — mỗi loại 1 ca PASS
      có byte/hash khớp Chrome ↔ app.

## 4. Logout / navigation / tab-close

- [ ] Logout Telegram giữa transfer → job invalidation rõ ràng, không báo thành công ảo.
- [ ] Navigation / đóng tab giữa transfer → selection mất hiệu lực.
- [ ] Mở viewer nhưng chưa mở media / nút Save chưa sẵn sàng → phân biệt đúng
      với `website_save_unavailable` (không kết luận quá sớm).

## 5. Disk / very-large-file (không mock được từ unit test)

- [ ] Hết dung lượng (ổ đầy thật hoặc quota): task `failed` với message rõ ràng
      chứa nguyên nhân disk, không crash, resume được sau khi dọn chỗ.
- [ ] Very-large file (sparse ~20 GB): hoàn tất + đo peak RSS trong lúc chạy.
- [ ] Sai hash / thiếu byte cuối: bị bắt ở bước validation (size + probe + media),
      không báo "hoàn tất" câm.

> Ghi chú: đã thử mock ENOSPC từ `DownloaderCoreTests` (ghi vào `/dev/full`)
> nhưng môi trường trả `EPERM` thay vì `ENOSPC`, và engine chưa có seam tiêm lỗi
> ghi file — nên ca hết-disk giữ ở checklist manual này thay vì test mock giòn
> (xem `docs/IDEAS_BACKLOG.md` E-I1 bản đầy đủ).
