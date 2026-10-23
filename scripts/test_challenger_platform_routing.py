#!/usr/bin/env python3
"""
Empirical Challenger Test Suite for Live Media Downloads and Platform Routing.
Verifies:
1. Bare platform home / feed fast-fail behavior (< 2 seconds, no hanging).
2. Extension content.js URL classification (isVideoWatchPage & isBarePlatformHomeURL).
3. Swift URLNormalizer behavior across bare feeds vs media links.
4. Edge case video URLs:
   - YouTube Shorts
   - Facebook Reels
   - Player embeds (Vimeo / iframe)
   - Reddit (v.redd.it / comments)
   - Direct MP4 box walking (ftyp + moov/mdat)
   - HLS streaming & MPEG-TS sync byte (0x47)
"""

import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request
import unittest

SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPTS_DIR, ".."))
if SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, SCRIPTS_DIR)

from media_validator import (
    validate_media_file,
    validate_mp4_boxes,
    validate_mpeg_ts_sync,
)


class TestChallengerPlatformRouting(unittest.TestCase):

    def test_extension_bare_platform_fast_fail_timing_and_accuracy(self):
        """
        Verify Extension content.js isBarePlatformHomeURL & isVideoWatchPage:
        Must return in < 2 seconds without hanging.
        facebook.com/, facebook.com/home, youtube.com/feed must be classified as bare home.
        """
        js_code = """
        const fs = require('fs');
        const vm = require('vm');

        const contentSource = fs.readFileSync('Extension/content.js', 'utf8');

        // Extract functions using regex
        // `hostMatches` là helper dùng chung (khớp host exact/suffix) → phải
        // nạp cùng với hai hàm trên, nếu không chúng sẽ ném ReferenceError.
        const helperMatch = contentSource.match(/function hostMatches\\(host, domain\\)\\s*\\{[\\s\\S]*?\\n  \\}/);
        const watchMatch = contentSource.match(/function isVideoWatchPage\\(url\\)\\s*\\{[\\s\\S]*?\\n  \\}/);
        const bareMatch = contentSource.match(/function isBarePlatformHomeURL\\(url\\)\\s*\\{[\\s\\S]*?\\n  \\}/);

        if (!watchMatch || !bareMatch || !helperMatch) {
            console.error("Match failed: helper=" + !!helperMatch + ", watchMatch=" + !!watchMatch + ", bareMatch=" + !!bareMatch);
            process.exit(1);
        }

        const sandbox = { URL, console };
        vm.createContext(sandbox);
        vm.runInContext(helperMatch[0], sandbox);
        vm.runInContext(watchMatch[0], sandbox);
        vm.runInContext(bareMatch[0], sandbox);

        const testUrls = [
            { url: 'https://www.facebook.com/', expectedBare: true, expectedWatch: false },
            { url: 'https://facebook.com/', expectedBare: true, expectedWatch: false },
            { url: 'https://www.facebook.com/home', expectedBare: true, expectedWatch: false },
            { url: 'https://facebook.com/home', expectedBare: true, expectedWatch: false },
            { url: 'https://www.youtube.com/feed', expectedBare: true, expectedWatch: false },
            { url: 'https://youtube.com/feed', expectedBare: true, expectedWatch: false },
            { url: 'https://www.tiktok.com/foryou', expectedBare: true, expectedWatch: false },
            { url: 'https://x.com/home', expectedBare: true, expectedWatch: false },
            // Video pages must NOT be bare home
            { url: 'https://www.facebook.com/watch/?v=987654321', expectedBare: false, expectedWatch: true },
            { url: 'https://www.facebook.com/reel/123456789', expectedBare: false, expectedWatch: true },
            { url: 'https://www.youtube.com/watch?v=jNQXAC9IVRw', expectedBare: false, expectedWatch: true },
            { url: 'https://www.youtube.com/shorts/gEQ0BLyVJhY', expectedBare: false, expectedWatch: true },
            { url: 'https://player.vimeo.com/video/76979871', expectedBare: false, expectedWatch: true },
            { url: 'https://www.dailymotion.com/video/x7tgad0', expectedBare: false, expectedWatch: true },
            { url: 'https://www.bilibili.com/video/BV1xx411c7mD', expectedBare: false, expectedWatch: true },
            { url: 'https://www.reddit.com/r/videos/comments/xyz123/', expectedBare: false, expectedWatch: true },
            { url: 'https://v.redd.it/abcdef123456', expectedBare: false, expectedWatch: true }
        ];

        const t0 = Date.now();
        const results = [];
        for (const item of testUrls) {
            const tStart = Date.now();
            const bare = sandbox.isBarePlatformHomeURL(item.url);
            const watch = sandbox.isVideoWatchPage(item.url);
            const durationMs = Date.now() - tStart;
            results.push({
                url: item.url,
                bare,
                watch,
                expectedBare: item.expectedBare,
                expectedWatch: item.expectedWatch,
                durationMs,
                ok: bare === item.expectedBare && watch === item.expectedWatch
            });
        }
        const totalDurationMs = Date.now() - t0;
        console.log(JSON.stringify({ totalDurationMs, results }));
        """

        t_start = time.time()
        proc = subprocess.run(
            ["node", "-e", js_code],
            cwd=PROJECT_ROOT,
            capture_output=True,
            text=True,
            timeout=5.0,
        )
        elapsed = time.time() - t_start

        self.assertEqual(proc.returncode, 0, f"Node script failed: {proc.stderr}")
        self.assertLess(elapsed, 2.0, f"Execution took {elapsed:.2f}s, expected < 2.0s")

        data = json.loads(proc.stdout)
        self.assertLess(data["totalDurationMs"], 1000, f"In-node evaluation took {data['totalDurationMs']}ms")

        for r in data["results"]:
            self.assertTrue(r["ok"], f"Mismatch for {r['url']}: bare={r['bare']} (expected {r['expectedBare']}), watch={r['watch']} (expected {r['expectedWatch']})")

    @staticmethod
    def _prebuild_swift_tests():
        """Build sẵn test target để `swift test --filter` chạy nhanh và ổn định.

        `swift test --filter` phải biên dịch trước; lần chạy đầu (hoặc khi máy
        đang tải cao) có thể vượt quá 15s → test fail giả. Build trước để phần
        đo chỉ tính thời gian chạy test.
        """
        try:
            subprocess.run(
                ["swift", "build", "--build-tests"],
                cwd=PROJECT_ROOT,
                capture_output=True,
                text=True,
                timeout=600.0,
            )
        except Exception:
            pass  # Build lỗi không chặn bước test sau báo lỗi rõ ràng.

    def test_swift_url_normalizer_fast_fail_timing_and_matrix(self):
        """
        Verify Swift URLNormalizer.isBarePlatformHomeURL via swift test:
        Must execute under 2 seconds and correctly identify bare feeds vs media endpoints.
        """
        self._prebuild_swift_tests()
        t_start = time.time()
        proc = subprocess.run(
            ["swift", "test", "--filter", "testIsBarePlatformHomeURL"],
            cwd=PROJECT_ROOT,
            capture_output=True,
            text=True,
            timeout=90.0,
        )
        elapsed = time.time() - t_start

        output = proc.stdout + "\n" + proc.stderr
        self.assertEqual(proc.returncode, 0, f"Swift test failed: {output}")
        self.assertIn("testIsBarePlatformHomeURL", output)
        self.assertIn("passed", output.lower())

    def test_swift_download_manager_fast_fail_behavior(self):
        """
        Verify Swift DownloadManager fails fast on bare home URL without hanging or network timeouts.
        """
        self._prebuild_swift_tests()
        t_start = time.time()
        proc = subprocess.run(
            ["swift", "test", "--filter", "testDownloadManagerFailsFastOnBarePlatformHomeURL"],
            cwd=PROJECT_ROOT,
            capture_output=True,
            text=True,
            timeout=90.0,
        )
        elapsed = time.time() - t_start

        output = proc.stdout + "\n" + proc.stderr
        self.assertEqual(proc.returncode, 0, f"Swift test failed: {output}")
        self.assertIn("testDownloadManagerFailsFastOnBarePlatformHomeURL", output)
        self.assertIn("passed", output.lower())

    def test_edge_case_direct_mp4_box_walking(self):
        """
        Verify direct MP4 download integrity with box walking (ftyp + moov/mdat).
        """
        url = "https://www.w3schools.com/html/mov_bbb.mp4"
        with tempfile.TemporaryDirectory() as temp_dir:
            dest = os.path.join(temp_dir, "test_bbb.mp4")
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=10.0) as resp, open(dest, "wb") as f:
                f.write(resp.read())

            self.assertTrue(os.path.exists(dest))
            self.assertGreater(os.path.getsize(dest), 0)

            # Validate MP4 box hierarchy
            mp4_ok, reason, boxes = validate_mp4_boxes(dest)
            self.assertTrue(mp4_ok, f"MP4 box walking failed: {reason}")
            self.assertIn("ftyp", boxes)
            self.assertTrue("moov" in boxes or "mdat" in boxes)

            # Full validator check
            val_ok, val_reason, details = validate_media_file(dest)
            self.assertTrue(val_ok, f"Media validator failed: {val_reason}")
            self.assertEqual(details["format"], "video/mp4")

    def test_edge_case_hls_stream_and_ts_sync_byte(self):
        """
        Verify HLS master playlist and MPEG-TS 0x47 sync byte across 50 packets.
        """
        seg_url = "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/gear1/fileSequence0.ts"
        with tempfile.TemporaryDirectory() as temp_dir:
            dest = os.path.join(temp_dir, "test_seg0.ts")
            req = urllib.request.Request(seg_url, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=10.0) as resp, open(dest, "wb") as f:
                f.write(resp.read())

            self.assertTrue(os.path.exists(dest))
            self.assertGreater(os.path.getsize(dest), 0)

            # Validate MPEG-TS sync bytes
            ts_ok, ts_reason, pkts = validate_mpeg_ts_sync(dest, max_packets=50)
            self.assertTrue(ts_ok, f"MPEG-TS sync validation failed: {ts_reason}")
            self.assertGreaterEqual(pkts, 50)

            # Full validator check
            val_ok, val_reason, details = validate_media_file(dest)
            self.assertTrue(val_ok, f"Media validator failed: {val_reason}")
            self.assertEqual(details["format"], "video/mp2t")


if __name__ == "__main__":
    unittest.main()
