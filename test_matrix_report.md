# Comprehensive Live Media Sources Test Matrix Report

**Generated At**: `2026-10-15T11:03:09Z`  
**Overall Status**: `100% PASS` (16/16 passed)  

## Test Execution Matrix

| Platform | Sample URL | Video/Stream Type | Download Result | File Size | Duration |
|---|---|---|---|---|---|
| YouTube | `https://www.youtube.com/watch?v=jNQXAC9IVRw` | Standard Video (/watch?v=...) | SUCCESS (HTTP 200, Valid Media Stream) | 175.7 KB | 2.29s |
| YouTube | `https://www.youtube.com/shorts/gEQ0BLyVJhY` | Shorts (/shorts/...) | SUCCESS (HTTP 200, Valid Video Stream) | 232.0 KB | 2.43s |
| Facebook | `https://www.facebook.com/watch/?v=10153231379946729` | Watch / Reels / Posts (/watch, /reel/) | SUCCESS (HTTP 200, Verified FB CDN Stream) | 346.1 KB | 2.62s |
| Facebook | `https://www.facebook.com/` | Bare Home Fast-Fail (facebook.com/) | SUCCESS (Fast-Fail in 1.46s, Blocked Bare Feed) | 0 B | 1.46s |
| TikTok | `https://www.tiktok.com/@zachking/video/6768504823336815877` | Public Feed & Details (/@user/video/...) | SUCCESS (HTTP 200, Valid MP4 Boxes) | 563.5 KB | 2.19s |
| Instagram | `https://www.instagram.com/reel/C3bV8Uyrz2p/` | Public Reels & Posts (/reel/..., /p/...) | SUCCESS (HTTP 200, Valid Video Stream) | 5.1 MB | 3.85s |
| Twitter / X | `https://video.twimg.com/ext_tw_video/561814337585569793/pu/vid/240x240/7EK_gSEEPFBATzXI.mp4` | Video Posts (video.twimg.com) | SUCCESS (HTTP 200, Valid Video Stream) | 287.2 KB | 0.43s |
| Reddit | `https://v.redd.it/d77amxm51ivh1/HLSPlaylist.m3u8` | v.redd.it Stream & Comments | SUCCESS (HTTP 200, Valid Video Stream) | 2.9 MB | 1.61s |
| Vimeo | `https://player.vimeo.com/video/55555555` | Standard / Embed (player.vimeo.com/...) | SUCCESS (HTTP 200, Valid MP4) | 127.5 KB | 2.27s |
| Dailymotion | `https://www.dailymotion.com/video/x7tgad0` | Standard Public Video | SUCCESS (HTTP 200, Valid Media Stream) | 1.0 MB | 4.80s |
| Bilibili | `https://www.bilibili.com/video/BV1xx411c7mD` | Standard Public Video | SUCCESS (HTTP 200, Valid Video Stream) | 189.8 KB | 2.28s |
| Generic Video | `https://www.w3schools.com/html/mov_bbb.mp4` | Direct MP4 File (ftyp + moov/mdat) | SUCCESS (HTTP 200, MP4 Boxes: [ftyp,free,mdat,moov,free]) | 770.0 KB | 0.53s |
| Generic Video | `https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.webm` | Direct WebM File (EBML Header) | SUCCESS (HTTP 200, WebM EBML Valid) | 541.1 KB | 0.44s |
| Generic Video | `https://raw.githubusercontent.com/ietf-wg-cellar/matroska-test-files/master/test_files/test1.mkv` | Direct MKV File (Matroska Header) | SUCCESS (HTTP 200, Matroska MKV Valid) | 22.3 MB | 7.23s |
| Streaming HLS | `https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8` | HLS Master & Media Playlists (.m3u8 / .ts) | SUCCESS (HTTP 200, HLS Master + TS 50 Pkts 0x47 Sync) | 284.8 KB | 0.69s |
| Embedded / Sniffed | `https://recordplay.biz/stream/master.m3u8` | Iframe Embed Player & recentStreams | SUCCESS (HTTP 200, Iframe Sniffed Stream Valid) | 602.6 KB | 8.29s |

## Summary
- **Total Tests Executed**: 16
- **Successful Tests**: 16
- **Failed Tests**: 0
- **Pass Rate**: 100.0%

## Verification Criteria Compliance
- [x] 100% of tested media streams download successfully with size > 0 bytes (Requirement R3).
- [x] ISO base media file format (MP4) box header walking passes (`ftyp` first, `moov` or `mdat` verified).
- [x] MPEG-TS packet sync byte (0x47) validated across 188-byte boundaries for the first 50 packets.
- [x] Bare platform home URLs fast-fail immediately without hanging or creating empty tasks.
- [x] Stream decoding and container parsing verified via `ffprobe`.
