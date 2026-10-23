# Review v2 — Internet Downloader, 2026-10-10

> **Snapshot cho 1.1.0/1.3.0** — tài liệu này là snapshot lịch sử tại thời điểm app 1.1.0 / extension 1.3.0 / browser protocol 2 (2026-10-10). Source hiện tại đã ở app 1.2.0 / extension 1.4.0; không dùng số phiên bản trong này để đối chiếu release hiện tại.

**Đã triển khai và cài app 1.1.0, extension source/package 1.3.0, browser protocol 2 trong Internet Downloader hiện tại. Chưa đóng toàn bộ nghiệm thu Telegram.** Chrome thật đã đạt một lát cắt Save video tổng hợp → DownloadItem → file Chrome → nhập app → validation. Telegram Web K/A và ma trận Chrome còn thiếu, giữ NOT VERIFIED.

## Đối chiếu nguyên nhân và thay đổi

Hai job 302 cũ dùng nguồn Web K `/k/stream/…`, failed/0 byte. Bản cũ chuyển nguồn trình duyệt tới engine HTTP độc lập, lấy `resp.media[0]`/URL trang khi gặp Blob, báo đã gửi trước ACK app, và URLNormalizer bỏ tiền tố Blob. Không có capture Location của hai 302; không suy đoán đích redirect. Service Worker của Telegram có logic đọc từng phần qua phiên client; nguồn này không trở thành CDN URL độc lập chỉ bằng cách theo redirect. [Telegram Web K stream](https://github.com/TelegramOrg/Telegram-web-k/blob/125a31da7665d5ee09ceb9c5de66e2615e3276b6/src/lib/serviceWorker/stream.ts).

Đã chặn Telegram Web/Blob ở URLNormalizer, entry IPC và đường HTTP; bỏ fallback sang nguồn đầu/URL trang. Regression trước sửa thất bại ba assertion, sau sửa qua. Hai job 302 cũ giữ bằng chứng, không tự retry. Job mới dùng browser adapter và native Save do UI cho phép, capability job/session, copy chunk 64 KiB/ACK, staging hash/size, công bố tên không ghi đè, giữ bản Chrome.

Extension dùng scripting trong tab/frame được chọn, kiểm tra fingerprint, quan sát URL phát sinh đồng bộ quanh chính thao tác Save rồi nối đúng một DownloadItem mới. URL/tên/thời gian đơn lẻ không được dùng để đoán download. Async/Save As kéo dài/album/menu không chứng minh được một mục chuyển needs_confirmation sau 16 giây, chọn file complete rõ ràng và ghi USER_CONFIRMED. Không thêm debugger. [Chrome scripting](https://developer.chrome.com/docs/extensions/reference/api/scripting), [Chrome downloads](https://developer.chrome.com/docs/extensions/reference/api/downloads).

App có cột browser_info nullable, marker URL about:blank cho browser job, sourceKind/method/kind/proof/phase/tier/hash/validation/error. Không lưu session/token/locator/media URL/auth của browser job trong SQLite. Migration giữ job cũ. Slot actor giới hạn hai job chung với HTTP/HLS. Retry browser yêu cầu chọn lại; navigation/tab-close/disconnect/restart làm selection mất hiệu lực. Native host chỉ mở bundle chứa nó, không ưu tiên bản cũ ở Applications.

Redirect HTTP có delegate tối đa 10 bước; scheme/boundary browser được kiểm tra, request đổi origin bỏ auth/cookie và các header nhạy cảm, cookie storage tự động tắt. HTML bị từ chối cho media cả khi MIME khai báo và khi prefix HTML ẩn dưới octet-stream. [Apple redirect delegate](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:willperformhttpredirection:newrequest:completionhandler:)).

## Bằng chứng offline cuối

Runtime: macOS 27.0 (26A428), Swift 6.4; FFmpeg/ffprobe local. `bash scripts/run_tests.sh`: **26 test Swift + 11 test extension PASS**, không test bị skip. Build release, app signature/plist và JS syntax đạt.

| Nhóm | Evidence đã đạt | Giới hạn |
|---|---|---|
| Chọn nguồn | Blob, Web K stream/page bị chặn; source đổi/glyph/permission; bỏ media[0]/page fallback | Telegram thực tế chưa đạt canary |
| ACK/version | success=false, thiếu taskId/token, app cũ bị từ chối; toast sau ACK | Reload refinement cuối trên Chrome còn chờ |
| Transfer | Native host binary thật + Unix socket + app actor chuyển **33554459 byte**, 64 KiB/ACK, hash và bản nguồn giữ nguyên | Đây là protocol fixture, không là DownloadItem Telegram thật; peak memory chưa đo |
| File | Sai offset, chunk quá giới hạn, thiếu byte, hash lệch, không ghi đè; invalid video/audio/image bị từ chối; video/ảnh đúng decode đạt | Hết dung lượng và very large file còn NOT VERIFIED |
| Vòng đời | Shared hai slot, queued/cancel/release, bad token không hủy job đúng, disconnect/restart invalidation | Full Chrome tab/logout/two-tab matrix chưa chạy |
| SQLite | Migration schema cũ giữ payload; browser metadata không session/token/media URL | Job legacy được giữ nguyên theo yêu cầu |
| HTTP | URLSession/server thật: redirect tới file, loop, thiếu Location, đổi origin không cookie, HTML rõ/ẩn MIME | Không suy từ đây ra mọi website |

Logs/artifacts local, không đưa locator Telegram vào báo cáo:

- `.runtime/telegram-v2/guard-red.log`
- `.runtime/telegram-v2/offline-check.log`
- `.runtime/telegram-v2/extension-tests.log`
- `.runtime/telegram-v2/release-delivery.log`
- `.runtime/telegram-v2/final-check.json`
- `.runtime/telegram-v2/installer-idle-guard.log` — installer từ chối thay bản khi app còn chạy.

## Chrome thật

Chrome **154.0.8037.99**, profile đang dùng. Extension ID cũ `nljinpcahdihnlhidjdacnhlchlpblnk`, source ở `Extension`, đã Reload 1.3.0 và popup xác nhận kết nối macOS App. Canary video tổng hợp qua popup chọn Save, có Save As thật. File Chrome và file app giữ riêng.

| Thuộc tính | Kết quả |
|---|---|
| Job fixture | BD7EC365-70D0-459E-9597-4EF2ED966906 |
| Phát hiện | Selected native Save trong DOM fixture |
| Proof | native_action_exact_url → unique new DownloadItem → downloadId |
| Transport | browser_download → host file copy/chunks |
| Output | **104495 byte**, H.264 320×180, **6.000000 giây** |
| SHA256 nguồn/Chrome/app | **ae1b59e4bff940c77e932406bc0b798dc0b491eaf025785620cdab85bfdcf843** — cả ba khớp |
| Validation | media_decode_and_transport; ffprobe và FFmpeg decode độc lập ở 0/3/4 giây đạt |
| Tier | VERIFIED cho đúng canary này |
| Evidence | `.runtime/telegram-v2/chrome-sync-canary.json` |

Canary trên chạy trước refinement cuối cho popup/deadline/cancellation/HTML guard. Các refinement cuối đã qua suite và build; chưa rerun toàn bộ Chrome matrix trên build cuối. Một job browser mới trong lúc làm việc dừng source_changed/0 byte; không có locator lưu trong SQLite để quy về chat/mục cụ thể, không coi là nghiệm thu Telegram thành công và không tự retry.

**NOT VERIFIED:** Chrome Save async → chọn file USER_CONFIRMED end-to-end; unrelated simultaneous downloads/same filename/two tabs; mất tab/logout/navigation thực tế; Telegram K/A đang đăng nhập với attachment người dùng chọn; các loại voice/photo/sticker/document và album thực tế; hết dung lượng/very large file với đo memory. Offline fixture chỉ xác minh logic các ca đã ghi, không nâng tier những ca này.

Công cụ Chrome nhiều lần trả “The user changed…” và cuối lượt trả “The user is still interacting…”. Cửa sổ riêng tên IDM nghiệm thu đã tạo, nhưng chưa xác minh được reload cuối/async canary trong lúc cửa sổ thay đổi. Không chuyển sang đọc hoặc tải các chat khác để thay ca còn thiếu.

## Rollout và bàn giao

Build staging không xóa dist. Snapshot đầu `.runtime/telegram-v2/rollout` giữ database/manifest/bundle trước; sau rollout đầu **ba row cũ và hai output cũ** nguyên vẹn.

Installer cuối `scripts/install_release.py` kiểm tra app rảnh/đã quit, stage identity/signature và kiểm tra lại trước swap. Snapshot **`.runtime/rollout-20261010-034635`** giữ **6 row + 4 output**, bundle/Extension/ZIP/manifest trước. Sau mở build cuối, **6 row và 4 size/hash không đổi**. App chạy đúng dist bundle, handshake 1.1.0/protocol 2; Telegram stream giả để kiểm tra bị từ chối trước tạo job với browser_source_required/discovery. Source extension và package dist khớp byte.

Build bàn giao: `dist/Internet Downloader.app`, `dist/Internet-Downloader-Extension.zip`, `dist/Extension`. Chrome đã chạy 1.3.0 ở canary đầu; **cần Reload extension lần nữa và Reload tab Telegram** để chắc chắn nạp các refinement cuối. Host manifest Chrome trỏ đúng helper trong dist bundle. Hướng dẫn thao tác/cài/rollback ở BROWSER_SETUP.md; trạng thái mốc và các ca còn thiếu ở PLAN_V2.md.

Không ghi plan hoàn thành chỉ từ build/test/fixture. Cần attachment Telegram bình thường do người dùng chọn, có Download/Save gốc khả dụng, để chạy K rồi A và ghi bằng chứng byte/file tương ứng.

## Hotfix thông báo và scope viewer — 2026-10-10

Người dùng báo luôn thấy “Telegram không cho lưu mục này”. Đã tái hiện **lỗi của adapter**, chưa xác định nguyên nhân trên attachment của người dùng: khi media nằm trong `.media-viewer` bên trong `.media-viewer-whole`, selector lấy scope gần nhất và không thấy thanh Save bên ngoài. Mã nguồn Web K pinned `125a31da7665d5ee09ceb9c5de66e2615e3276b6`, `src/components/mediaViewer/base.ts`, đặt thanh topbar và movers cạnh nhau trong whole viewer. Ca không có Save hoặc media chưa mở trong viewer cũng bị dùng chung `website_save_unavailable`, gây kết luận quyền lưu quá sớm.

Hotfix ưu tiên whole viewer, chỉ xét `no-forwards` trên mục/ancestor/viewer đã chọn, và phân biệt thiếu nút, nút chưa sẵn sàng, chưa mở viewer với hạn chế lưu. Không tìm hoặc gọi manager nội bộ; chỉ kích hoạt Save gốc khả dụng. Một descendant không thuộc mục được chọn không trở thành bằng chứng chặn lưu.

Test Node có ba failure trước sửa; sau sửa **14 test PASS, 0 skip**, gồm scope có media/toolbar tách nhau, thiếu/disabled Save, permission thay đổi và unrelated descendant. Log: `.runtime/telegram-save-diagnosis/red.log`, `green.log`. Syntax JS và diff-check đạt. Chrome Katou thực tế đã hiển thị **Reloaded** cho extension ID cũ 1.3.0, source `~/Projects/Internet-Downloader/Extension`. Lần kiểm tra sau reload không thấy tab Telegram trong hai cửa sổ Chrome hiện có, nên **attachment người dùng và transfer Telegram vẫn NOT VERIFIED**; không mở chat cũ thay thế. Database/app bundle không cần thay trong hotfix extension này.

## Hotfix ưu tiên nút Save khả dụng trên chat có cờ no-forwards — 2026-10-10 (Lượt 2)

Người dùng phản hồi lựa chọn B: trên giao diện Telegram Web thật, nút Download gốc của Telegram vẫn hiện diện và có thể click tải thủ công bình thường, nhưng extension vẫn báo "Telegram đang bật hạn chế lưu mục này".

Nguyên nhân cốt lõi phát hiện ở lượt 2:
1. `Extension/telegram.js`: Hàm `prepare()` trước đây kiểm tra `if (restricted(el, scope)) throw Error('website_save_unavailable');` trước khi tìm kiếm các nút Save (`saves`). Trong các nhóm, kênh hoặc bot bật chặn chuyển tiếp tin nhắn (anti-forwarding/noforwards), Telegram gắn class `.no-forwards` lên bong bóng/khung chat, nhưng Telegram vẫn cung cấp nút Download gốc hợp lệ cho media. Việc kiểm tra `.no-forwards` trước đã chặn nhầm mọi file trong các chat này dù nút Download sẵn sàng.
2. `Extension/browser-transfer.js`: Trong `triggerBrowserSave()`, điều kiện `save.closest('.no-forwards')` cũng khiến việc click nút Save bị từ chối với mã lỗi `source_changed`.

Giải pháp:
1. Sửa `Extension/telegram.js`: Ưu tiên tìm kiếm các nút Save hợp lệ trước. Chỉ kiểm tra `restricted(el, scope)` khi `!saves.length` (không tìm thấy nút Save nào). Nếu Telegram đã cung cấp nút Save thì cho phép kích hoạt ngay.
2. Sửa `Extension/browser-transfer.js`: Gỡ bỏ điều kiện `save.closest('.no-forwards')` trong `triggerBrowserSave()`, thay bằng kiểm tra `save.getAttribute?.('aria-disabled') === 'true'`.
3. Bổ sung unit test trong `Tests/ExtensionTests/browser.test.cjs`: `Telegram Save button in a restricted-forwarding chat is allowed when native Save is available`. Toàn bộ 15 test Node PASS.
4. Chạy toàn bộ test suite (`scripts/run_tests.sh`): 26 test Swift + 15 test Extension PASS 100%, exit code 0.
5. Đồng bộ `dist/Extension` và `dist/Internet-Downloader-Extension.zip` khớp byte hoàn toàn.
