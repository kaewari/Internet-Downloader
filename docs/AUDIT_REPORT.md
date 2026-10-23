# AUDIT REPORT — Internet-Downloader (full-code review, 2026-10-23)

Nguồn: 5 lane workers read-only (A: Core Engine · B: Storage/IPC/NativeHost · C: SwiftUI App · D: Extension MV3 · E: Tests/Scripts/Docs) + lead static sweep.
Quy tắc: mọi finding có `file:line` + evidence; không bịa; P1 = crash/mất dữ liệu/lỗ hổng bảo mật/sai cam kết release; P2 = nên sửa cùng branch; P3 = follow-up.
Working tree tại lúc audit: HEAD `d50ffb4`, dirty ~27 file (Engine + Extension + App). Excluded: `.build/`, `Downloads/`, `dist/`, `test_downloads/`, `.runtime/`.

## 0. Dashboard

| Lane | Files | Findings | P1 | P2 | P3 |
|---|---|---|---|---|---|
| A Engine (16 file, DownloadManager 1765 + HLS 1015 + Resolver 876 + Range 699) | 16 | 20 | 7 | 10 | 3 |
| B Storage/IPC/Host (9 file) | 9 | 11 + 1 good | 4 | 4 | 3 |
| C App (7 file) | 7 | 18 | 3 | 9 | 6 |
| D Extension (9 file, ~3.9k LOC JS) | 9 | 16 | 3 | 8 | 5 |
| E Tests/Scripts/Docs | ~30 | 17 | 4 | 6 | 7 |
| **Tổng sau dedup** | ~70 file | **~80 (2 trùng root-cause đã gộp)** | **~21** | **~35** | **~24** |

Lead sweep: JS syntax OK (6/6 `node --check` pass); version source đồng bộ (VERSION 1.2.0 = AppVersion 1.2.0, ext 1.4.0 = manifest 1.4.0, `check_versions.sh` canh 6 nguồn); 1 `fatalError` + ~110 `!` trong DownloadManager (workers đã verify từng điểm).

## 1. Top P1 — sửa trước (đủ repro/static-proof)

### 1.1 Crash / memory-safety
- **A-F1 `DownloadManager.swift:48` — `fatalError` khi không mở được SQLite → crash cả daemon.** Fix: fallback DB tạm/memory + báo failed. Effort M (3h human / 45' CC).
- **B-B1 `SQLiteStore.swift:147` (+ :148-153,156-164,170-193,367,379,447-453) — `sqlite3_bind_text(..., nil)` = SQLITE_STATIC với pointer tạm `(… as NSString).utf8String` → use-after-free.** Chỉ :197/:202 dùng đúng TRANSIENT. Fix: đổi mọi bind sang TRANSIENT. Effort S. **Đây là P1 nặng nhất phía native.**
- **A-F2 `DownloadManager.swift:40,53,113` + `:20` — `.first!` + IUO `browserTransfers!`.** Fix: guard + lazy non-optional. Effort S.

### 1.2 Mất dữ liệu / resume sai
- **B-B3 `SQLiteStore.swift:430-463` + `:114-213` — checkpoint không atomic (saveTask/saveSegments 2 txn riêng, không BEGIN/COMMIT; grep 0 hit).** Crash giữa chừng → `downloaded_bytes` lệch segments. Fix: bọc trong 1 txn. Effort M.
- **A-F7 `HTTPRangeDownloader.swift:504-522` — resume không gửi If-Range/If-Match dù đã lưu etag/lastModified.** Fix: thêm If-Range + xử lý 412/416 → re-probe. Effort M.
- **A-F4 `HLSDownloader.swift:595,652` — IV mặc định dùng `seg.index` thay vì Media Sequence Number.** Playlist có `EXT-X-MEDIA-SEQUENCE != 0` → giải mã hỏng. Fix: parse media-seq + index. Effort M.
- **A-F5 `HLSDownloader.swift:287-290,983-984` — nhận mọi METHOD != NONE (kể cả SAMPLE-AES) rồi decrypt AES-128-CBC → rác không lỗi.** Fix: chỉ chấp nhận AES-128, throw rõ cho còn lại. Effort S (quick-win).
- **A-F6 `HLSDownloader.swift:975,980-989` — byterange chấp nhận 200 như thành công, ghi nguyên body → concat nhân đôi.** Fix: yêu cầu 206 hoặc slice. Effort M.
- **A-F3 `DownloadManager.swift:21,1407-1408` — `taskStrippedCookies: Set<UUID>` truy cập từ nhiều Task không lock → data race.** Fix: lock/actor. Effort S (quick-win).

### 1.3 Bảo mật
- **B-B4 `UnixDomainSocketServer.swift:5,24,66` — socket `/tmp` đoán trước + không auth peer + chmod sau bind (TOCTOU).** Process local bất kỳ có thể gửi `start_download`/`browser_*`. Fix: chuyển vào dir per-user 0700 + check uid + chmod ngay khi tạo. Effort M.
- **B-B2 `SQLiteStore.swift:35,52,54` — persist `url/cookies/headers/referrer/user_agent` plaintext, vi phạm REVIEW_V2.** Fix: chỉ giữ trong memory/Keychain, DB lưu hash/null. Effort M.
- **D-F1 `Extension/popup/popup.js:112-118` — XSS via `innerHTML` với `${item.url}`/mime do server kiểm soát → XSS trong privileged popup (gọi mọi `chrome.*`).** Fix: dựng DOM bằng textContent/setAttribute. Effort S.
- **D-F2 `Extension/background.js:678-683,685-719` — không validate `sender`; content `all_frames:true` nên iframe hostile cũng gọi `get_captured_media`/`download_media` kèm cookie (`:866-903`).** Fix: chỉ phục vụ top-frame/active-tab + allowlist. Effort M.
- **D-F3 `Extension/telegram.js:47-50` — `no-forwards` bị bypass khi vẫn tìm thấy nút Save (chỉ check trong `if (!saves.length)`).** Đi ngược ý định 2 hotfix gần nhất. Fix: ném `website_save_unavailable` ngay khi restricted. Effort S.
- **A-F16 + D-F10 (GỘP — cùng root-cause) `URLNormalizer.swift:104-113` + `background.js:778-798,872-876` — so 2 nhãn cuối → `evil.co.uk` vs `shop.co.uk` cùng base → leak cookie/ giữ cookie sang site lạ.** Fix: eTLD+1 (public-suffix list) hoặc tối thiểu 3 nhãn. Effort S-M.

### 1.4 UI treo / jank nặng
- **C-F1 `DownloadManagerViewModel.swift:107-129` — progress callback publish mỗi tick → re-render toàn bộ List + sidebar `count()` 11 lần filter.** Fix: throttle 2-4 Hz + chỉ publish khi hiển thị + delta đáng kể. Effort M.
- **C-F2 `SegmentVisualizerView.swift:39-66,101-128` — rebuild 8-16 bar + tạo LinearGradient mới mỗi tick.** Fix: Equatable + cache gradient + throttle 4 Hz. Effort S-M.
- **C-F3 `DownloadManagerViewModel.swift:153-190` — `refreshTasks()` chạy FileManager/magic-byte/moveItem/saveTask đồng bộ trên MainActor.** Fix: chuyển sang background rồi publish. Effort M.

### 1.5 Cam kết release / test
- **E-F1 — Không có CI (thiếu `.github/workflows/`); mọi PASS trong TEST_READY đều từ máy dev.** Fix: thêm `ci.yml` chạy `check_versions.sh --no-dist` → `run_tests.sh`. Effort M.
- **E-F4 `NonMediaIntegrityTests.swift:477,542` — 2 test live (GitHub PDF/ZIP) không XCTSkip khi mất mạng + copy vào `Downloads/`.** Timeout 20s làm gate đỏ khi rate-limit. Fix: preflight + skip như mẫu Facebook + bỏ copy. Effort S.
- **E-F2/E-F3 — very-large-file/hết disk/peak-memory + matrix 2-tab/async Save-As/album/logout/navigation vẫn NOT VERIFIED (REVIEW_V2:25-26,58; PLAN_V2:37), không test nào đo (grep ENOSPC/peak = 0).** Fix: test diskFull mock + sparse-very-large + 2-tab-isolation + Chrome-matrix checklist. Effort M (xem IDEAS I1).

## 2. P2 chọn lọc (làm cùng branch, mỗi mục 1 dòng + file:line)

**Engine:**
- A-F8 `HLSDownloader:553-559` resume HLS chỉ check size>0 → segment cụt coi xong. Lưu expectedLen/hash sampling. M.
- A-F9 `HLSDownloader:936-1001` HLS không retry (RetryPolicy chỉ cho Range). Bọc retry 3× + Retry-After. M.
- A-F10 `RetryPolicy:4-5,26-32` backoff khai [1,2,4] chỉ dùng [1,2]; Retry-After bỏ HTTP-date; thiếu 408/timeout. Sửa + dùng chung cho HLS/yt-dlp. S (quick-win).
- A-F11 `HTTPRangeDownloader:538-549` không xử lý 416 riêng → re-probe + rebuild segments. M.
- A-F12 `DownloadManager:394,470` + `MediaURLResolver:458-460` giữ 1 trong 2 slot trong lúc yt-dlp 30s → starve hàng đợi. Resolve trước acquire / slot riêng. L (1d).
- A-F13 `DownloadManager:6-1765` god-class + `queue` concurrent chết (`:11`, grep 1 hit). Tách Resolve/Probe/Orchestrator/Mux/YtDlp; xóa queue. L (3-5d, 4 PR).
- A-F14 `HLSDownloader:538-548,632` + `DM:1186` fake segment (0-100) persist vào bảng HTTP → DB/UI sai. Model HLSSlotProgress riêng. M.
- A-F15 `HLSDownloader:515,770-777` chỉ lấy initMap.first, bỏ DISCONTINUITY; thiếu ffmpeg thì move .ts→.mp4 sai container. Theo dõi init/segment + bắt remux. M.
- A-F19 `DataURLHandler:37-48` + `Range:381-389` data: URL load nguyên vào RAM → OOM. Chặn >64MB / streaming. M.

**Storage/IPC:**
- B-B5 `SQLiteStore:8-22` thiếu WAL/busy_timeout/synchronous → SQLITE_BUSY fail ngay. Thêm 3 PRAGMA. S (quick-win).
- B-B6 `SQLiteStore:225-235,274` 1 row hỏng (browser_info try throw) giết cả getAllTasks. Decode tolerant try? + log. S.
- B-B7 `NativeHost/main.swift:184` origin check bypass khi argc==1 (`count>1 && ...`). Fail-closed bắt buộc. S.
- B-B8 `UnixDomainSocketServer:83-101` accept spawn Task không giới hạn + RCVTIMEO 40s → DoS/fd exhaustion. Semaphore + idle timeout. S.

**App:**
- C-F4 `InternetDownloaderApp:24-37` đóng window = quit ngay cả khi đang tải, không confirm. Hỏi/giữ nền. M.
- C-F5 `VM:65-85,348-355` cướp focus mỗi task (activate + bringWindowsToFront). Chỉ khi active/gộp banner. S.
- C-F6 `VM:246-247,311-313,325-326,361-363` lỗi serious chỉ print, không toast; row cắt 1 dòng. Thêm errorBanner tập trung. M.
- C-F7 `MainWindow:101-106` + `VM:329-335` nút Dọn dẹp 2 nghĩa + destructive không confirm. Tách action + Alert. S.
- C-F8 `MainWindow:129-139` + `VM:269-279` sheet ESC dismiss lọt onCancel → task needsConfirmation mồ côi. interactiveDismissDisabled/onDismiss. S.
- C-F9 `NewDownloadDialog:36-38,126-157` ghi đè filename user + cho rỗng lọt. dirty-flag + validate. S.
- C-F10 `MainWindow:49-67` task list dùng onTapGesture thay List(selection:) → gãy keyboard/VoiceOver; sidebar NavigationLink không navigationDestination. Sửa. M.
- C-F11 `TaskRowView:96-158,48-91` nút 22×22 + icon-only, progress không a11y value, segment chỉ phân biệt màu. Nâng hit-target/label. S-M.
- C-F12 `MainWindow:50,142-156` + `VM:192-217` mỗi render filter ~12 lần + fileExt copy 3 nơi. Cache 1-pass + helper chung. S.

**Extension:**
- D-F4 `telegram.js:40-41` saveControl(array) → TypeError, scan nuốt catch. Sửa `saveControl(el)`. S.
- D-F5 `browser-transfer.js:62-75` vs `telegram.js:17-18` thiếu spinner-check → TOCTOU click nút loading → needs_confirmation oan. Mirror điều kiện. S.
- D-F6 `background.js:110-140` hydrate async không await trong khi listeners sync → mất headers/dedup sau wake. Gate trên promise hydrate. M.
- D-F7 `browser-transfer.js:10-46,107-137` job/port chỉ RAM, chết theo SW suspend → kẹt needs_confirmation. Persist storage.session + resume. M.
- D-F8 `background.js:375-389,280-291` cancel+erase trước ACK, fallback tải trần mất auth + tabId=null mất toast. Erase sau ACK + truyền tabId. M.
- D-F9 `background.js:707-719` vs `:685-691` batch thiếu validator blob:/data:. Dùng chung hàm validate. S.
- D-F11 `browser-transfer.js:214-221` + `browser-popup.js:37-48` confirm chấp nhận mọi download id (30 file không lọc intents) → import nhầm. Lọc theo intents + cảnh báo. S.

**Tests/Docs:**
- E-F5 TEST_READY:155-156 lệch counts (108→125 Swift, 51→62 Node do quên feedback 11 test; report 136/0/4 vs 94/46 vs 210/210). Sửa + ghi ngày. S.
- E-F6 PLAN_V2/REVIEW_V2 còn 1.1.0/1.3.0 trong khi code 1.2.0/1.4.0. Thêm header "snapshot lịch sử". S.
- E-F7 `100_media_sources.md` stale (Exactly 100/9.14GB vs catalog 154 + report 140; mô hình full→head+tail). Đánh dấu lịch sử. S.
- E-F8 fixture thiếu AES-128/fMP4/byterange/403-Referer (`media_server.py:34-52`, `http_redirect.py` 18 dòng, `/cross` localhost vs 127.0.0.1). Thêm 3 endpoint. M.
- E-F9 TEST_READY:148 "14 lỗi" vs AUDIT D1-D16 (thiếu D15/D16 HLS-audio). Sửa 16. S.
- E-F10 hardcoded `/opt/homebrew/bin`, `/Users/hoangson/...` (HLSAdvanced:481,565; BrowserTransfer:239; browser_fixture.py:20). Helper find_ffmpeg + XCTSkip. S.

## 3. P3 chọn lọc (follow-up, 1 dòng mỗi mục)

A-F17 `DownloadSlots:44-56` release chỉ wake 1 waiter dù còn capacity → under-utilize. Wake tới khi full. S (quick-win). · A-F18 `HTTPRange:228-239` probe nuốt catch → fallback HEAD/throw. S. · A-F20 `MediaURLResolver:675` + `HLS:892,959` + `DM:1406` loạt `first!/vcodec!/cookies!` giòn → guard + swiftlint. S. · B-B9 `SQLiteStore:398,403,419,425` trùng mã NSError 14/15/16 → enum. S. · B-B10 `SocketServer:110-115` mọi lỗi gộp "Invalid IPC frame" → map BrowserFailure + stage. S. · B-B11 `SocketServer:7-10,73-80` state @unchecked Sendable không lock → NSLock/actor. S. · C-F13 `VM:49,132-151` clipboardTimer không invalidate/deinit. S. · C-F14 `VM:59-129` 6 callback Task{@MainActor} fire-forget mỗi tick → coalesce. S. · C-F15 App `MenuBarExtra:59-88` không %/pause + filter mỗi tick; thiếu Dock progress. M. · C-F16 `TaskRow:282-302` ByteCountFormatter mỗi row/tick + badge needsConfirmation lạc style. Cache + pill thống nhất. S. · C-F17 New/Confirmation/Refresh dialog `runModal` chặn main + probe không cancel + fallback .mp4 cứng + paste invalid no-op. beginSheetModal + cancel-check. S-M. · C-F18 `Confirmation:152-158` onChange(task.filename) dead-code (let prop). Bỏ/truyền taskId. S. · D-F12 `manifest:7-21` permissions rộng (tabs/notifications/cookies + <all_urls> + all_frames) → activeTab/optional + minimum_chrome_version. S. · D-F13 sniffer FP/FN biên (?format=m3u8, videoplayback, download.php, /v2.0/download). Sniff query+MIME. M. · D-F14 toast trùng (accepted+completed) / thiếu (popup silent + pdf-viewer catch). Chỉ toast terminal + fallback. S. · D-F15 2 watchdog/handoff phân kỳ (`:613-633` vs `:717-795`). Gom 1 helper. S. · D-F16 telegram scan toàn trang + filename cứng + cap 200. Giới hạn scope + sinh tên theo mid/index. S. · E-F11 shell thiếu `set -euo pipefail` (run/build vs mẫu install_native_host). S. · E-F12 version-parser copy 3 nơi (build/check/install_release). Tách lib chung. S. · E-F13 mirror JS thủ công (`browser-transfer:8`, `popup:54`) → sinh generated từ AppVersion. S. · E-F14 `MediaSourceConfigTests:14` CWD-relative → resolve từ #filePath. S. · E-F15 `HTTPRedirectTests:5-13` spawn fixture không timeout → treo. Thêm 5s + XCTFail. S. · E-F16 3 script deprecated/one-shot gây nhiễu → archive/. S. · E-F17 bare except + thiếu timeout vài helper → thu hẹp + log. S.

## 4. Điểm đã kiểm chứng là ĐÚNG (không mở issue)

- Off-by-one Range đúng: `calculateSegments:351-352` (end=total-1), Range inclusive + clamp (`Range:580-583`), expectedBytes (`DownloadSegment:20-23`).
- `206` khi Accept-Ranges được reset+discard đúng (`Range:561-568`); thiếu tương đương ở HLS (A-F6) và 416 (A-F11) mới là issue.
- DownloadSlots không deadlock (pendingCancel + cancellation hop đúng); chỉ under-utilize (A-F17).
- Socket IPC dùng big-endian nhất quán 2 đầu (không phải bug); chỉ Native Messaging mới cần LE và đã đúng (`main.swift:22,45`).
- Framing SocketFrame đúng (split read/write, EINTR loop, cap 1MiB, 40s timeout); copyCompletedDownload tốt (O_NOFOLLOW + ino/size/mtime + hash 2 vòng).
- Version source đồng bộ (không lệch): VERSION/AppVersion/manifest/browser-transfer/popup đều 1.2.0/1.4.0; lệch chỉ ở docs lịch sử.
- `bash -n` + `py_compile` pass toàn bộ scripts; `install_release.py` idle-guard/snapshot tốt.

## 5. Rủi ro còn NOT VERIFIED (giữ nguyên tier, không nâng)

Very-large-file / hết disk / peak-RSS; matrix Chrome thật 2-tab/async Save-As/album/logout/navigation; Telegram K/A attachment thật (voice/photo/sticker/document); HLS live ENDLIST; behavior CDN trả 200 thay 206 cho byterange. Offline fixture chỉ cover logic đã ghi.

## 6. Đề xuất thứ tự sửa (theo plan-eng-review: complete-option trước)

1. **Security hotfix (0.5-1d):** B-B1 TRANSIENT + D-F1 XSS + D-F2 sender-gate + B-B4 socket path/auth + gộp A-F16/D-F10 eTLD+1 + D-F3 no-forwards.
2. **Data-integrity (1-2d):** B-B3 txn + A-F7 If-Range/416 + A-F4 IV + A-F5 SAMPLE-AES reject + A-F6 byterange-206 + A-F8 resume-verify.
3. **Stability (0.5d):** A-F1/F2/F3 + B-B5 WAL + B-B6 tolerant-decode + B-B7/B-B8.
4. **UI jank (1d):** C-F1/F2/F3 + C-F12/F14 + D-F6/F7/F8.
5. **Gate (0.5d):** E-F1 CI + E-F4 tách live + E-F5/F6/F7/F9 docs-sync + E-F8 fixture.
6. **God-class + scheduler (chia 4 PR, 3-5d):** A-F12/F13/F14 + I4 (TransferScheduler v2).

## Phụ lục: coverage workers

A: 16 file Engine + DownloadSegment (off-by-one) — full; chưa chắc yt-dlp locale, FileAssembler defer-in-for, live ENDLIST. B: 9 file scope + AppVersion + BrowserFileValidation — full; chưa fuzz framing/runtime. C: 7 file App — full 100%; ngoài scope Core/IPC/entitlements/Instruments. D: 9 file Extension + diff hotfix + browser.test.cjs + AppVersion mirror — full; telegram.js không có diff nên claim 2 hotfix suy từ code. E: 12 Swift + 3 Node + 2 fixture + ~20 scripts + Package/README/TEST_READY/docs/VERSION — full; đếm thật 125 Swift / 62 Node.
