#!/usr/bin/env python3
"""
Tests for the offline media fixture server (`Tests/Fixtures/media_server.py`).

The fixture server is the deterministic, network-free reproduction of the two
user-reported video bugs:

  * HLS master playlists with a separate `#EXT-X-MEDIA:TYPE=AUDIO` rendition
    must be downloadable with both video AND audio.
  * A direct video-only `.mp4` URL must be detectable as "no audio" instead of
    being silently completed.

These tests only exercise the fixture server itself (playlists, media bytes,
headers, byte ranges, broken-audio 404, clean shutdown). Swift integration
tests consume the same server.

Run:
    python3 scripts/test_media_server_fixture.py

Requires ffmpeg/ffprobe (auto-detected at /opt/homebrew/bin; skipped with a
clear message when missing). Stdlib only.
"""

from __future__ import annotations

import json
import os
import re
import selectors
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER_PATH = os.path.join(ROOT, "Tests", "Fixtures", "media_server.py")

FFMPEG_CANDIDATES = [
    os.environ.get("FFMPEG"),
    "/opt/homebrew/bin/ffmpeg",
    "/usr/local/bin/ffmpeg",
    "/usr/bin/ffmpeg",
    shutil.which("ffmpeg"),
]
FFPROBE_CANDIDATES = [
    os.environ.get("FFPROBE"),
    "/opt/homebrew/bin/ffprobe",
    "/usr/local/bin/ffprobe",
    "/usr/bin/ffprobe",
    shutil.which("ffprobe"),
]

STARTUP_TIMEOUT = 120.0
STOP_TIMEOUT = 20.0


def _find_binary(candidates, name):
    for candidate in candidates:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def find_ffmpeg():
    return _find_binary(FFMPEG_CANDIDATES, "ffmpeg")


def find_ffprobe():
    return _find_binary(FFPROBE_CANDIDATES, "ffprobe")


class ServerStartError(RuntimeError):
    pass


class ServerHandle:
    """A running fixture server subprocess with captured stderr."""

    def __init__(self, proc, port, first_stdout_line, stderr_chunks, stderr_thread):
        self.proc = proc
        self.port = port
        self.first_stdout_line = first_stdout_line
        self._stderr_chunks = stderr_chunks
        self._stderr_thread = stderr_thread
        self.base_url = f"http://127.0.0.1:{port}"

    def stderr_text(self):
        return "".join(chunk.decode("utf-8", "replace") for chunk in self._stderr_chunks)

    def stop(self, timeout=STOP_TIMEOUT):
        """Stop the server (SIGTERM) and return its exit code."""
        if self.proc.poll() is None:
            self.proc.terminate()
        try:
            returncode = self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            returncode = self.proc.wait(timeout=timeout)
        self._stderr_thread.join(timeout=2)
        self._close_pipes()
        return returncode

    def _close_pipes(self):
        for pipe in (self.proc.stdout, self.proc.stderr):
            if pipe is not None:
                try:
                    pipe.close()
                except OSError:
                    pass


def start_server(extra_args=None, timeout=STARTUP_TIMEOUT):
    """Start media_server.py on an ephemeral port and wait for its port JSON."""
    cmd = [sys.executable, SERVER_PATH, "--port", "0"] + list(extra_args or [])
    proc = subprocess.Popen(
        cmd,
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert proc.stdout is not None and proc.stderr is not None

    stderr_chunks = []

    def _drain_stderr():
        try:
            for raw in iter(proc.stderr.readline, b""):
                stderr_chunks.append(raw)
        except (ValueError, OSError):
            pass

    stderr_thread = threading.Thread(
        target=_drain_stderr, name="fixture-stderr-drain", daemon=True
    )
    stderr_thread.start()

    first_line = b""
    port = None
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + timeout
    try:
        while time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            events = selector.select(timeout=min(remaining, 1.0))
            if not events:
                if proc.poll() is not None:
                    break
                continue
            line = proc.stdout.readline()
            if not line:
                break
            text = line.decode("utf-8", "replace").strip()
            if not text:
                continue
            first_line = line
            try:
                payload = json.loads(text)
            except json.JSONDecodeError:
                continue
            if isinstance(payload, dict) and isinstance(payload.get("port"), int):
                port = payload["port"]
                break
    finally:
        selector.close()

    if port is None:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=STOP_TIMEOUT)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
        stderr_thread.join(timeout=2)
        stderr_text = "".join(c.decode("utf-8", "replace") for c in stderr_chunks)
        for pipe in (proc.stdout, proc.stderr):
            try:
                pipe.close()
            except OSError:
                pass
        raise ServerStartError(
            "fixture server did not print a {\"port\": N} JSON line on stdout.\n"
            f"stdout: {first_line!r}\nstderr:\n{stderr_text}"
        )

    # Sanity check: the announced port really is listening.
    deadline = time.monotonic() + 10
    while True:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                break
        except OSError:
            if time.monotonic() >= deadline:
                raise ServerStartError(
                    f"fixture server announced port {port} but is not accepting connections"
                )
            time.sleep(0.05)

    return ServerHandle(proc, port, first_line, stderr_chunks, stderr_thread)


def _http_request(base_url, path, headers=None, method="GET", timeout=30):
    request = urllib.request.Request(
        base_url + path, headers=headers or {}, method=method
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, dict(response.headers), response.read()
    except urllib.error.HTTPError as error:
        return error.code, dict(error.headers), error.read()


def _stream_kinds(path_or_url):
    """Return the stream codec types ffprobe sees (e.g. ['video','audio'])."""
    ffprobe = find_ffprobe()
    if not ffprobe:
        raise unittest.SkipTest("ffprobe không khả dụng — bỏ qua kiểm tra stream")
    proc = subprocess.run(
        [
            ffprobe, "-v", "error",
            "-show_entries", "stream=codec_type",
            "-of", "csv=p=0", path_or_url,
        ],
        capture_output=True, text=True, timeout=60,
    )
    if proc.returncode != 0:
        raise AssertionError(
            f"ffprobe failed for {path_or_url}: {proc.stderr.strip()[-800:]}"
        )
    kinds = []
    for line in proc.stdout.splitlines():
        kind = line.strip()
        if kind and kind not in kinds:
            kinds.append(kind)
    return kinds


class MediaFixtureServerTests(unittest.TestCase):
    """End-to-end checks against one live fixture-server instance."""

    @classmethod
    def setUpClass(cls):
        if find_ffmpeg() is None:
            raise unittest.SkipTest(
                "ffmpeg không khả dụng (cần cho Tests/Fixtures/media_server.py). "
                "Cài bằng `brew install ffmpeg` hoặc đặt biến FFMPEG."
            )
        cls.tmp_root = tempfile.mkdtemp(prefix="idm-media-fixture-test-")
        try:
            cls.server = start_server(["--root", cls.tmp_root])
        except ServerStartError as error:
            shutil.rmtree(cls.tmp_root, ignore_errors=True)
            raise unittest.SkipTest(str(error))
        cls.base_url = cls.server.base_url

    @classmethod
    def tearDownClass(cls):
        server = getattr(cls, "server", None)
        if server is not None:
            returncode = server.stop()
            stderr_text = server.stderr_text()
            shutil.rmtree(getattr(cls, "tmp_root", ""), ignore_errors=True)
            if returncode != 0:
                raise AssertionError(
                    f"fixture server did not exit cleanly (rc={returncode}):\n{stderr_text[-2000:]}"
                )

    def request(self, path, headers=None, method="GET"):
        return _http_request(self.base_url, path, headers=headers, method=method)

    # -- protocol --------------------------------------------------------

    def test_server_prints_port_json_on_stdout(self):
        first_line = self.server.first_stdout_line.decode("utf-8", "replace").strip()
        payload = json.loads(first_line)
        self.assertEqual(payload, {"port": self.server.port})
        self.assertIsInstance(payload["port"], int)
        self.assertGreater(payload["port"], 0)
        self.assertLessEqual(payload["port"], 65535)
        self.assertIsNone(self.server.proc.poll(), "server phải còn sống sau khi báo port")

    # -- HLS fixtures ----------------------------------------------------

    def test_master_playlist_declares_separate_audio_rendition(self):
        status, headers, body = self.request("/hls/master.m3u8")
        self.assertEqual(status, 200)
        self.assertIn("mpegurl", headers.get("Content-Type", "").lower())
        text = body.decode("utf-8")

        self.assertIn("#EXTM3U", text)
        media_lines = [l for l in text.splitlines() if l.startswith("#EXT-X-MEDIA:")]
        self.assertEqual(len(media_lines), 1, f"cần đúng 1 EXT-X-MEDIA, thấy: {media_lines}")
        media = media_lines[0]
        for fragment in (
            "TYPE=AUDIO",
            'GROUP-ID="aud"',
            'NAME="vi"',
            "DEFAULT=YES",
            "AUTOSELECT=YES",
            'URI="aud.m3u8"',
        ):
            self.assertIn(fragment, media)

        stream_lines = [l for l in text.splitlines() if l.startswith("#EXT-X-STREAM-INF:")]
        self.assertEqual(len(stream_lines), 1)
        stream = stream_lines[0]
        for fragment in ("BANDWIDTH=", 'AUDIO="aud"', "RESOLUTION="):
            self.assertIn(fragment, stream)

        variant_lines = [l.strip() for l in text.splitlines() if l.strip() and not l.startswith("#")]
        self.assertEqual(variant_lines, ["vid.m3u8"], "variant phải là URI tương đối vid.m3u8")

    def test_video_and_audio_media_playlists_parse(self):
        expectations = {
            "/hls/vid.m3u8": ["vid-0.ts", "vid-1.ts"],
            "/hls/aud.m3u8": ["aud-0.ts", "aud-1.ts"],
        }
        for path, expected_segments in expectations.items():
            with self.subTest(path=path):
                status, headers, body = self.request(path)
                self.assertEqual(status, 200)
                self.assertIn("mpegurl", headers.get("Content-Type", "").lower())
                text = body.decode("utf-8")
                self.assertTrue(text.startswith("#EXTM3U"))
                self.assertIn("#EXT-X-TARGETDURATION:", text)
                self.assertIn("#EXT-X-ENDLIST", text)
                self.assertEqual(text.count("#EXTINF:"), 2)
                segments = [l.strip() for l in text.splitlines() if l.strip() and not l.startswith("#")]
                self.assertEqual(segments, expected_segments)
                self.assertTrue(all(s.endswith(".ts") for s in segments))

    def test_ts_segments_are_real_mpegts(self):
        for name in ("vid-0.ts", "vid-1.ts", "aud-0.ts", "aud-1.ts"):
            with self.subTest(segment=name):
                status, headers, body = self.request(f"/hls/{name}")
                self.assertEqual(status, 200)
                self.assertEqual(headers.get("Content-Type"), "video/mp2t")
                self.assertEqual(headers.get("Accept-Ranges"), "bytes")
                self.assertEqual(int(headers.get("Content-Length", "-1")), len(body))
                self.assertGreater(len(body), 188, "segment MPEG-TS phải có ít nhất 1 packet")
                self.assertEqual(len(body) % 188, 0, "MPEG-TS phải là bội số của 188 byte")
                self.assertEqual(body[0], 0x47, "MPEG-TS phải bắt đầu bằng sync byte 0x47")

    def test_hls_broken_master_points_audio_at_404(self):
        status, _, body = self.request("/hls-broken/master.m3u8")
        self.assertEqual(status, 200)
        text = body.decode("utf-8")
        match = re.search(r'URI="(/hls-broken/[^"]+)"', text)
        self.assertIsNotNone(match, f"không tìm thấy audio URI trong: {text}")
        audio_uri = match.group(1)
        self.assertEqual(audio_uri, "/hls-broken/aud-missing.m3u8")

        status, _, _ = self.request(audio_uri)
        self.assertEqual(
            status, 404,
            "audio rendition của master hỏng phải trả 404 để app FAIL thay vì "
            "xuất bản video không tiếng",
        )
        # The video variant of the broken master is still valid; only audio is gone.
        status, _, _ = self.request("/hls/vid.m3u8")
        self.assertEqual(status, 200)

    # -- Direct renditions ----------------------------------------------

    def test_direct_video_only_mp4_headers_and_no_audio_stream(self):
        status, headers, body = self.request("/direct/video-only.mp4")
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("Content-Type"), "video/mp4")
        self.assertEqual(headers.get("Accept-Ranges"), "bytes")
        self.assertEqual(int(headers.get("Content-Length", "-1")), len(body))
        self.assertGreater(len(body), 0)

        kinds = _stream_kinds(f"{self.base_url}/direct/video-only.mp4")
        self.assertIn("video", kinds)
        self.assertNotIn(
            "audio", kinds,
            "fixture /direct/video-only.mp4 phải KHÔNG có luồng audio (tái hiện lỗi mất tiếng)",
        )

    def test_direct_mp4_supports_single_byte_ranges(self):
        status, headers, body = self.request("/direct/video-only.mp4")
        self.assertEqual(status, 200)
        total = len(body)

        status, headers, body = self.request(
            "/direct/video-only.mp4", headers={"Range": "bytes=0-99"}
        )
        self.assertEqual(status, 206)
        self.assertEqual(headers.get("Content-Range"), f"bytes 0-99/{total}")
        self.assertEqual(headers.get("Content-Type"), "video/mp4")
        self.assertEqual(int(headers.get("Content-Length", "-1")), 100)
        self.assertEqual(len(body), 100)

        status, headers, body = self.request(
            "/direct/video-only.mp4", headers={"Range": "bytes=-64"}
        )
        self.assertEqual(status, 206)
        self.assertEqual(
            headers.get("Content-Range"), f"bytes {total - 64}-{total - 1}/{total}"
        )
        self.assertEqual(len(body), 64)

        status, headers, body = self.request(
            "/direct/video-only.mp4", headers={"Range": f"bytes={total + 5}-"}
        )
        self.assertEqual(status, 416)
        self.assertEqual(headers.get("Content-Range"), f"bytes */{total}")

    def test_direct_audio_only_m4a_has_audio_and_ranges(self):
        status, headers, body = self.request("/direct/audio-only.m4a")
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("Content-Type"), "audio/mp4")
        self.assertEqual(headers.get("Accept-Ranges"), "bytes")
        self.assertEqual(int(headers.get("Content-Length", "-1")), len(body))
        self.assertGreater(len(body), 0)

        kinds = _stream_kinds(f"{self.base_url}/direct/audio-only.m4a")
        self.assertIn("audio", kinds)
        self.assertNotIn("video", kinds)

        status, headers, body = self.request(
            "/direct/audio-only.m4a", headers={"Range": "bytes=0-31"}
        )
        self.assertEqual(status, 206)
        self.assertEqual(len(body), 32)
        self.assertTrue(headers.get("Content-Range", "").startswith("bytes 0-31/"))

    # -- Referrer page ---------------------------------------------------

    def test_video_only_html_page_references_the_mp4(self):
        status, headers, body = self.request("/page/video-only.html")
        self.assertEqual(status, 200)
        self.assertIn("text/html", headers.get("Content-Type", "").lower())
        text = body.decode("utf-8")
        self.assertIn("<title>Fixture video</title>", text)
        self.assertIn("<video", text)
        self.assertIn('src="/direct/video-only.mp4"', text)

    # -- Lifecycle -------------------------------------------------------

    def test_sigterm_shuts_down_cleanly(self):
        # Reuse the class fixture root so this second server starts instantly.
        server = start_server(["--root", self.tmp_root])
        try:
            self.assertIsNone(server.proc.poll())
        finally:
            returncode = server.stop()
        self.assertEqual(
            returncode, 0,
            f"server phải thoát với mã 0 khi nhận SIGTERM, nhận {returncode}:\n"
            f"{server.stderr_text()[-2000:]}",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
