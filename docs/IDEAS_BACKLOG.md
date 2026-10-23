# IDEAS BACKLOG — Internet-Downloader (ý tưởng tốt từ audit 5 lane)

Chấm nhanh: Impact Cao/Trung Bình/Thấp · Effort S (≤0.5d) / M (0.5-2d) / L (3d+) · Quick-win = thấy kết quả trong ngày.
Thứ tự bên dưới đã sort theo (P1-closer trước, quick-win trước).

## Quick-win (làm hôm nay, ≤1 ngày)

| # | Ý tưởng | Đóng issue nào | Impact / Effort |
|---|---|---|---|
| Q1 | Throttle + coalesce progress pipeline (VM gộp 3-4 Hz, chỉ emit khi hiển thị + delta; SegmentBar/TaskRow Equatable, cache gradient, drawingGroup) — C-I1 | C-F1/F2 | Cao / S-M ✅ |
| Q2 | Gom helper + cache counts/filtered (FileTypeHelper chung thay 3 bản, Dictionary(grouping:) 1 pass, ByteCountFormatter static) — C-I2 | C-F12/F16 | TB / S ✅ |
| Q3 | `WAL + busy_timeout 5s + synchronous NORMAL` + `user_version` cho migration — B-I1 | B-B5 | TB-Cao / S ✅ |
| Q4 | Ngừng persist `headers` (bản nhỏ của secrets hygiene), strip query-token trước khi lưu — B-I3-part | B-B2 | Cao / S ✅ |
| Q5 | Từ chối `SAMPLE-AES` sớm + retry HLS segment/key 3× — A-I3-part | A-F5/F9 | Cao / S ✅ |
| Q6 | ETag-only resume-verifier (If-Range trước, sampling-hash sau) — A-I2-part | A-F7 | Cao / S ✅ |
| Q7 | Sửa RetryPolicy (điều kiện attempt, parse HTTP-date, mở rộng 408/timeout) + cho HLS dùng chung — A-F10 | A-F9/F10 | TB / S ✅ |
| Q8 | Wake đủ waiter trong DownloadSlots + guard thay force-unwrap + swiftlint — A-F17/F20 | A-F17/F20 | TB / S ✅ |
| Q9 | Gom dedup/normalize thành `media-key.js` chung cho SW + content — D-I2 | D-F13 | TB / S ✅ |
| Q10 | Receipt toast duy nhất (chỉ toast terminal phase, background fallback khi popup đóng) — D-I4 | D-F14 | TB / S ✅ |
| Q11 | Gọi `check_versions.sh --no-dist` trong `run_tests.sh` + sửa TEST_READY counts (125/62) + header snapshot cho docs V2 — E-I2-part | E-F5/F6 | TB / S ✅ |
| Q12 | Guard `IDM_RUN_LIVE` cho 2 test live + thêm `/referer-403` vào fixture — E-I3/I4-part | E-F4/F8 | Cao / S ✅ |
| Q13 | Shortcuts + hit-target/a11y label (⌘N/Space/⌫/⌘O, ≥28pt, progress value, badge pill) — C-I4-part | C-F10/F11 | TB / S ✅ |

## Backlog chính (M-L, impact lớn)

| # | Ý tưởng | Nội dung gọn | Impact / Effort |
|---|---|---|---|
| I1 | Bandwidth estimator + adaptive concurrency (EWMA thay mean 2s, Range 2→8 segment, HLS hạ variant khi speed < 0.8×BW) — A-I1 | +20-40% throughput mạng tốt, ít fail mạng yếu | Cao / M-L (2-3d) |
| I2 | Resume-verifier đầy đủ (If-Range + ETag compare + sampling hash 64KB + 416 rebuild) — A-I2 | Chống file hỏng âm thầm sau resume | Cao / M (1d) |
| I3 | HLS robustness pack (MEDIA-SEQUENCE cho IV + init-map theo segment + DISCONTINUITY + live ENDLIST refresh) — A-I3/A-F15 | HLS hết fail câm, live cơ bản chạy | Cao / M (2d) |
| I4 | TransferScheduler v2 (tách resolve/probe khỏi slot 2-task; slot theo connection ~6 toàn cục; HLS mượn conn thay vì 4 cứng) — A-I4 | Hết starve yt-dlp 30s, kiểm soát tải thực | Cao / L (3-5d) |
| I5 | Hash-verify pipeline (fsync + checksum sampling + mở rộng completionSizeGate thành size+probe+media) — A-I5 | Bắt rớt byte cuối mà size vẫn khớp | TB-Cao / M (1-2d) |
| I6 | Batch checkpoint (1 txn saveTask+saveSegments, reuse prepared stmt, throttle 1s + khi pause/segment-xong) — B-I2 | Giảm I/O, resume chính xác | Cao / M |
| I7 | Protocol v3 (requestId + nonce/HMAC per-session, socket vào $TMPDIR/<uid>, hello bắt buộc trước action) — B-I4 | Chặn injection/replay local | Cao / M |
| I8 | Installer guard (verify IDM_APP_PATH + allowed_origins + chmod + version chéo) — B-I5 | Hết "bấm mà không có gì xảy ra" | TB / S ✅ |
| I9 | Error/toast tập trung + validation dialog thống nhất (banner chung, throw về UI, disable Start khi invalid) — C-I3 | Hết silent-fail F6/F9 | TB-Cao / M (1 phần quick-win) |
| I10 | Onboarding empty-state + MenuBar/Dock progress + quit an toàn (3 bước thử, % tổng + pause-all, badge, confirm khi đang tải) — C-I5 | First-run + background UX đúng chất IDM | TB / M |
| I11 | E2E harness MV3 suspend + native-mock (kill-SW giữa start→confirm, drop port, double-click dedup) — D-I1 | Khóa F6/F7/F8 bằng regression | Cao / M |
| I12 | Selector resilience + health test (role/data-attr trước class; assert JS ⊂ Swift knownPlatforms) — D-I3 | Giảm gãy theo đổi DOM | TB / M |
| I13 | Permission diet + sender allowlist (activeTab, notifications→optional, bỏ all_frames nơi không cần, cookie theo eTLD+1) — D-I5 | Security posture | Cao / M |
| I14 | E2E matrix tối thiểu: disk-guard (ENOSPC mock) + very-large-sparse 20GB + 2-tab-isolation — E-I1 | Đóng 2/3 lỗ P1-F2/F3 offline | Cao / M (1-2d; bản (a) S hôm nay) |
| I15 | Fixture contract duy nhất (gộp media_server + http_redirect + browser_save.html; thêm hls-enc/hls-fmp4/referer-403/html-hidden/chunked-nolength + endpoint table) — E-I3 | Hết inline-data trùng, determinism | TB-Cao / M (1d) |
| I16 | Tách live khỏi `swift test` (marker IDM_RUN_LIVE + nightly job live + upload matrix) — E-I4 | Hết flaky gate, offline exit 0 nhanh | TB / S |
| I17 | Docs-as-code STATUS sinh tự động (VERSION + AppVersion + manifest + đếm test + matrix JSON → bảng) — E-I5 | Docs không bao giờ lệch | TB / S (2h; bản tay 5') |

## Không làm / tách scope (ghi rõ để khỏi trôi)

- Rewrite DownloadManager 1 lần (quá rủi ro) → chia 4 PR theo seam Resolve/Probe/Orchestrator/Mux/YtDlp (A-F13).
- Live Chrome thật + Telegram K/A thật + album/voice/sticker → manual checklist + nightly riêng, không nhét vào gate offline (E-F3, REVIEW_V2:58).
- Thay SQLite bằng GRDB/CoreData → không cần; WAL + txn + batch đã đủ (B-I1/I2).
- MV3 `debugger` API → đã khóa đúng (browser.test.cjs), không mở lại.

## Nguồn traceability

Mỗi ý tưởng giữ ID gốc lane để đối chiếu: A-I1..I5 (Engine) · B-I1..I5 (Storage/IPC) · C-I1..I5 (App) · D-I1..I5 (Extension) · E-I1..I5 (Tests/Ops). Chi tiết evidence đầy đủ trong `docs/AUDIT_REPORT.md` §1-3.
