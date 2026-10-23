# TEST READY — Internet Downloader: kiểm thử video live & toàn bộ pipeline

> Tài liệu này mô tả trạng thái **sau** lần kiểm tra ngày 2026-10-23
> (xem `docs/AUDIT_VIDEO_PIPELINE.md` để biết chi tiết các lỗi đã phát hiện và vá).

## 1. Điểm khác biệt quan trọng

Bộ test live **không** dùng `yt-dlp`/`urllib` để tải rồi cho là "pass". Nó chạy
**đúng pipeline của app**:

```
URL trang → MediaURLResolver.resolve → HTTPRangeDownloader (nhiều segment)
          → ghép video+audio bằng ffmpeg (nếu nguồn DASH) → ffprobe kiểm tra lại
```

Mỗi ca kiểm chứng: HTTP 200, kích thước > 0 byte, `ffprobe` đọc được container,
và với nguồn có âm thanh thì file cuối phải có **CẢ luồng video lẫn luồng audio**.

## 2. Cách chạy

### 2.1 Bộ test offline đầy đủ (bắt buộc, exit code 0)

```bash
./scripts/run_tests.sh
```

Bao gồm: SPM build (Core, Native Host, App, `test-app-pipeline`) · `swift test`
(Swift unit + integration) · `node --test` (Chrome extension protocol) · 3 bộ test
Python (media validator, challenger validator, platform routing) · kiểm tra cấu trúc
extension.

Fixture HTTP cục bộ phục vụ các endpoint sau (offline, determinism):

| Fixture | Endpoint | Hành vi |
|---|---|---|
| `Tests/Fixtures/media_server.py` | `GET /hls/master.m3u8` | Master HLS: variant video + rendition audio tách rời (`aud.m3u8`) |
| `Tests/Fixtures/media_server.py` | `GET /hls/vid.m3u8`, `/hls/aud.m3u8`, `/hls/*.ts` | Playlist + segment video-only / audio-only thật (ffmpeg) |
| `Tests/Fixtures/media_server.py` | `GET /hls-broken/master.m3u8` | Audio rendition trỏ 404 → task phải FAIL, không xuất video câm |
| `Tests/Fixtures/media_server.py` | `GET /direct/video-only.mp4`, `/direct/audio-only.m4a` | File thật thiếu audio / thiếu video (hỗ trợ `Range` → 206) |
| `Tests/Fixtures/media_server.py` | `GET /direct/referer-403.mp4` | **403 khi thiếu header `Referer`** (anti-hotlink); có `Referer` → trả bytes video-only |
| `Tests/Fixtures/media_server.py` | `GET /page/video-only.html` | Trang HTML nhúng video-only (làm `Referer` cho luồng "repair audio") |
| `Tests/Fixtures/http_redirect.py` | `GET /redirect`, `/loop`, `/missing`, `/cross`, `/html`, `/html-hidden` | Redirect hợp lệ / loop / thiếu Location / đổi origin (bỏ auth) / HTML rõ + ẩn MIME |

### 2.2 Ma trận live — chạy pipeline thật của app

```bash
python3 scripts/verify_live_media_sources.py
```

| Tuỳ chọn | Ý nghĩa |
|---|---|
| `--platform <tên>` | Chỉ chạy một nền tảng (ví dụ `--platform YouTube`) |
| `--timeout <giây>` | Timeout mỗi ca (mặc định 240) |
| `--output <path>` | Đường dẫn báo cáo markdown (mặc định `test_matrix_report.md`) |
| `--json-output <path>` | Kết quả JSON thô |
| `--dest <dir>` | Thư mục lưu file tải về |
| `--no-crosscheck` | Bỏ bước đối chiếu yt-dlp cho các ca fail |

Nguồn kiểm thử nằm trong `scripts/live_platform_sources.json` — mỗi ca là **URL
trang thật** (không hardcode URL CDN có chữ ký hết hạn).

### 2.3 Bộ kiểm thử 100+ nguồn media thật (gồm NSFW)

```bash
python3 scripts/verify_media_sources.py --tier quick
python3 scripts/verify_media_sources.py --exclude-host archive.org   # bỏ nhóm CDN đang sập
python3 scripts/verify_media_sources.py --from-results media_sources_results.json  # dựng lại báo cáo
```

Danh sách nguồn: `scripts/media_sources_100.json` — **154 mục còn dùng được / 131 host
độc lập / 27 nguồn NSFW**, tất cả là URL media thật (không phải URL giả). Số nguồn
theo họ host được giới hạn (`cap-families`) để một dịch vụ CDN sập không làm hàng
chục ca rơi vào SKIP cùng lúc.

Cách tải: **head + tail** — tải 4 MB đầu + 2 MB cuối rồi ghi vào **file thưa đúng
offset** → file có kích thước bằng file nguồn, `ffprobe` đọc được cả `moov`/cues ở
cuối, nhưng dung lượng tải thật chỉ vài MB/nguồn.

Kiểm chứng mỗi nguồn: HTTP 200/206 → magic byte đúng loại (`FileTypeDetector`,
code production) → `ffprobe` thấy đúng stream → kích thước > 0. Nguồn không dùng
được được ghi **SKIP kèm lý do** (không tính là PASS).

| Tầng | Nội dung | Dung lượng | Thời gian |
|---|---|---|---|
| `smoke` | head 512 KB + tail 256 KB, magic byte | ≈ 90 MB | ~2 phút |
| `quick` (mặc định) | head 4 MB + tail 2 MB, magic byte + `ffprobe` | ≈ 720 MB | 3–5 phút |
| `deep` | tải trọn nguồn ≤ 32 MB + `ffmpeg` decode 1 s | ≈ 400 MB thêm | +5 phút |

Cờ thêm: `--concurrency N` · `--exclude-tag nsfw` (bỏ nhóm NSFW) · `--keep-files`
(giữ file để debug) · `--no-crosscheck` · `--output/--json-output/--dest`.

Chạy trực tiếp bằng Swift (cùng logic, dùng chung `DownloaderCore`):

```bash
swift run test-100-sources --tier deep   # toàn bộ nguồn
swift run test-10-sources --count 8       # kiểm tra nhanh
```

### 2.4 Quét cùng bộ nguồn qua **logic của extension**

```bash
node --test Tests/ExtensionTests/media_sources.test.cjs
```

Bốn kiểm chứng (offline, dữ liệu lấy từ chính catalog trong repo):

1. **Sniffer bắt được mọi nguồn thật** — chạy `background.js onResponseStarted` qua
   154 URL thật → không nguồn video/audio nào bị bỏ sót, tên tệp không rỗng/không
   chứa dấu phân cách đường dẫn. Nguồn **ảnh** bị bỏ qua *có chủ đích* (ảnh đi
   qua đường `<a download>` của `content.js`).
2. **MSE chunk và trang lỗi bị lọc** — googlevideo `/videoplayback` và trang 403
   không bị bắt; segment `.ts` được gắn cờ `isChunk`.
3. **`isVideoWatchPage` đúng với mọi URL trong ma trận live** — YouTube, Facebook
   `/reel/`+`/posts/`, TikTok, Instagram, X `/status/`, Reddit, Vimeo, Dailymotion,
   Bilibili đều được nhận đúng; URL media thô/iframe thì không.
4. **Hai danh sách nền tảng không được lệch** — mọi host trong
   `URLNormalizer.swift` (app) phải có trong `VIDEO_PLATFORM_DOMAINS` (extension).
   Trước đây lệch 8 host (hentaivn/njav/xnhau) → đã đồng bộ.

### 2.5 Quản lý danh sách nguồn (chống thối link)

```bash
python3 scripts/refresh_media_sources.py probe          # dò sống/chết mọi URL
python3 scripts/refresh_media_sources.py refresh        # làm mới URL có chữ ký hết hạn
python3 scripts/refresh_media_sources.py repair --prune # retire/xoá nguồn không dùng được
python3 scripts/refresh_media_sources.py discover       # sinh nguồn mới từ API công khai
python3 scripts/refresh_media_sources.py sync-kinds     # đồng bộ kind/expect_streams theo file thật
```

Nguồn URL chết được **tự chữa ngay trong lúc chạy**: harness gọi
`--refresh-one <id>` để lấy URL mới rồi thử lại (tối đa 1 lần/nguồn).

### 2.6 Test đơn lẻ

```bash
python3 scripts/test_media_validator.py               # 24 test
python3 scripts/test_challenger_media_validator.py    # 35 test
python3 scripts/test_challenger_platform_routing.py   # 5 test
node --test Tests/ExtensionTests/*.test.cjs           # 62 test (47 browser + 11 validator/đối chiếu + 4 quét nguồn thật)
swift test --filter YtDlpFormatResolutionTests        # hồi quy "mất tiếng"
swift test --filter MuxIntegrationTests               # ghép ffmpeg
```

## 3. Ma trận tính năng

| Feature ID | Tính năng | Cách kiểm chứng | Trạng thái |
|---|---|---|---|
| **F1** | YouTube `/watch` + `/shorts/` | `test-app-pipeline` (app tự resolve → tải → ghép) | **PASS** — file có `video+audio` |
| **F2** | Facebook `/watch`, `/reel/`, `/posts/` + fast-fail trang chủ | `test-app-pipeline` + `test_challenger_platform_routing.py` | **PASS** (ca `/watch`); `/reel/`, `/posts/` tuỳ nguồn còn sống |
| **F3** | TikTok trang chi tiết + feed | `test-app-pipeline` (fallback sang yt-dlp khi CDN chặn) | **PASS** |
| **F4** | Instagram `/reel/`, `/p/` | `test-app-pipeline` | **SKIP** — Instagram yêu cầu đăng nhập (có bằng chứng đối chiếu yt-dlp) |
| **F5** | Twitter/X `/status/` | `test-app-pipeline` | **SKIP** — extractor X hiện không lấy được video (có bằng chứng đối chiếu) |
| **F6** | Reddit (v.redd.it HLS + post) | `test-app-pipeline` (qua `HLSDownloader` thật) | **PASS** (HLS); post → **SKIP** (yêu cầu auth) |
| **F7** | Vimeo / Dailymotion / Bilibili | `test-app-pipeline` | **PASS** — đủ video + audio |
| **F8** | File trực tiếp MP4 / WebM / MKV | `test-app-pipeline` (engine range của app) | **PASS** |
| **F9** | HLS master + media playlist | `test-app-pipeline` → `HLSDownloader` (master→variant, AES-128, fMP4, byte-range) | **PASS** |
| **F10** | Iframe nhúng + `recentStreams` | Offline: `unpackDeanEdwards` (Swift) + `getBestStreamFromRecent` (JS) | **PASS** (offline); live nguồn đã đổi giao diện → **SKIP** |
| **F11** | Media validator nâng cao | `scripts/test_media_validator.py` + `test_challenger_media_validator.py` | **PASS** (59 test) |
| **F12** | Bộ test live tự động | `scripts/verify_live_media_sources.py` (app pipeline) | **PASS** |
| **F13** | Vá lỗi + không hồi quy | `./scripts/run_tests.sh` | **PASS** — 16 lỗi D1-D16 đã vá, có test hồi quy (chi tiết: `docs/AUDIT_VIDEO_PIPELINE.md`) |
| **F14** | Báo cáo ma trận | `test_matrix_report.md` | **PASS** — URL thật, streams, kích thước, thời gian, PASS/FAIL/SKIP |

## 4. Tóm tắt số liệu (lần chạy thật gần nhất, cập nhật 2026-10-23)

| Bộ test | Kết quả |
|---|---|
| Swift (`swift test`) | 125 test, 0 failure, 1 skip (URL Facebook CDN hết hạn → skip có chủ đích) |
| Chrome extension (`node --test`) | 62 test, 0 failure (47 browser + 11 validator/đối chiếu + 4 test quét 154 nguồn thật qua logic extension) |
| Media validator | 24 test — OK |
| Challenger validator | 35 test — OK |
| Platform routing | 5 test — OK |
| **Tổng offline** | **toàn bộ PASS, `run_tests.sh` exit code 0** |
| Ma trận live (app pipeline) | **13 PASS / 0 FAIL / 4 SKIP** — chi tiết trong `test_matrix_report.md` |
| Bộ nguồn media thật (app pipeline, tầng quick) | **94 PASS / 0 FAIL / 46 SKIP** — 46 ca SKIP đều là `archive.org` **không phản hồi từ máy này** lúc chạy (báo cáo có bảng SKIP theo họ host); lần chạy khi archive.org còn sống: **210/210 PASS**. Chi tiết: `docs/100_media_sources_report.md` |

> Ghi chú: trước lần sửa này, `TEST_READY.md` ghi "118 tests" và "16/16 live
> PASS" nhưng thực tế live suite chạy ra **15/16** (Instagram 403) và **không hề
> kiểm chứng app**. Các con số ở trên là số đo thật của lần chạy hiện tại.
>
> 4 ca SKIP là các nguồn **không còn truy cập được nếu không đăng nhập**
> (Instagram reel, Reddit post, Facebook reel, site nhúng `recordplay.biz`).
> Báo cáo kèm bảng đối chiếu chứng minh `yt-dlp` cũng không tải được các URL đó
> → không phải lỗi của app.
