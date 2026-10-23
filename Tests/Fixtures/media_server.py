#!/usr/bin/env python3
"""
Offline deterministic media fixture server for Internet Downloader tests.

Why this exists
---------------
Two user-reported failures need to be reproducible without the network:

  1. HLS master playlists that declare a *separate* audio rendition
     (`#EXT-X-MEDIA:TYPE=AUDIO,...URI="aud.m3u8"`) used to be downloaded as
     video-only → the published file had no sound.
  2. Direct video-only `.mp4` URLs used to be downloaded and marked completed
     even though the file has no audio stream.

This server generates real (tiny) MPEG-TS/AAC/H.264 media with ffmpeg at
startup and serves it over HTTP 1.1 with byte-range support, so Swift
integration tests can drive the app's real download pipeline against
`http://127.0.0.1:<port>/...`.

Usage
-----
    python3 Tests/Fixtures/media_server.py [--port 0] [--root DIR] [--ffmpeg PATH]

It prints exactly one JSON line on stdout as soon as it is listening:

    {"port": 51789}

Everything else (fixture generation progress, request log) goes to stderr.
Pass `--port 0` (the default) to let the OS choose an ephemeral port.
Pass `--root DIR` to reuse a pre-built fixture directory (tests may build
once and start several servers); missing files are regenerated.

Endpoints
---------
    GET /hls/master.m3u8          HLS master: video variant `vid.m3u8` with a
                                  separate `TYPE=AUDIO` rendition `aud.m3u8`
    GET /hls/vid.m3u8             video-only media playlist, 2 TS segments
    GET /hls/aud.m3u8             audio-only media playlist, 2 TS segments
    GET /hls/vid-0.ts, vid-1.ts   video-only MPEG-TS segments (real bytes)
    GET /hls/aud-0.ts, aud-1.ts   audio-only MPEG-TS segments (real bytes)
    GET /hls-broken/master.m3u8   same master, but the audio rendition URI
                                  `/hls-broken/aud-missing.m3u8` returns 404
                                  (must make the download task FAIL, never
                                  publish a silent video-only file)
    GET /direct/video-only.mp4    real H.264 MP4 with NO audio stream
    GET /direct/audio-only.m4a    real AAC audio with NO video stream
    GET /direct/referer-403.mp4   403 unless the request carries a Referer
                                  header (anti-hotlink regression); with a
                                  Referer it serves video-only.mp4 bytes
    GET /page/video-only.html     HTML page with <video src="/direct/video-only.mp4">
                                  (usable as Referer for "repair audio" flows)
    GET /                         JSON index of the endpoints (debug helper)

`/direct/*.mp4`, `/direct/*.m4a` and the `.ts` segments support single byte
ranges (`Range: bytes=...` → 206) and advertise `Accept-Ranges: bytes`.

Only the Python standard library is imported; ffmpeg/ffprobe are external
binaries (Homebrew builds at /opt/homebrew/bin are auto-detected).
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit

HOST = "127.0.0.1"

FFMPEG_CANDIDATES = [
    os.environ.get("FFMPEG"),
    "/opt/homebrew/bin/ffmpeg",
    "/usr/local/bin/ffmpeg",
    "/usr/bin/ffmpeg",
    shutil.which("ffmpeg"),
]

CONTENT_TYPES = {
    ".m3u8": "application/vnd.apple.mpegurl",
    ".ts": "video/mp2t",
    ".mp4": "video/mp4",
    ".m4a": "audio/mp4",
    ".html": "text/html; charset=utf-8",
    ".json": "application/json",
}

# ---------------------------------------------------------------------------
# Playlist fixtures (written to <root>/hls/... and served as-is)
# ---------------------------------------------------------------------------

HLS_MASTER = """#EXTM3U
#EXT-X-VERSION:3
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="vi",LANGUAGE="vi",DEFAULT=YES,AUTOSELECT=YES,URI="aud.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=900000,AVERAGE-BANDWIDTH=800000,CODECS="avc1.42E01E",RESOLUTION=320x180,AUDIO="aud"
vid.m3u8
"""

HLS_VIDEO_PLAYLIST = """#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:2
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:2.000000,
vid-0.ts
#EXTINF:2.000000,
vid-1.ts
#EXT-X-ENDLIST
"""

HLS_AUDIO_PLAYLIST = """#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:2
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:2.000000,
aud-0.ts
#EXTINF:2.000000,
aud-1.ts
#EXT-X-ENDLIST
"""

# Same master as HLS_MASTER, but the audio rendition points at a playlist that
# does not exist (served as 404). The app must fail the task instead of
# silently publishing a video-only file.
HLS_BROKEN_MASTER = """#EXTM3U
#EXT-X-VERSION:3
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="vi",LANGUAGE="vi",DEFAULT=YES,AUTOSELECT=YES,URI="/hls-broken/aud-missing.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=900000,AVERAGE-BANDWIDTH=800000,CODECS="avc1.42E01E",RESOLUTION=320x180,AUDIO="aud"
/hls/vid.m3u8
"""

PAGE_VIDEO_ONLY = """<!doctype html>
<html lang="vi">
<head>
  <meta charset="utf-8">
  <title>Fixture video</title>
</head>
<body>
  <h1>Fixture video (direct video-only MP4)</h1>
  <video controls preload="none" width="320" height="180" src="/direct/video-only.mp4"></video>
</body>
</html>
"""

# Every file the server needs. Names are relative to the fixture root.
FIXTURE_FILES = [
    "hls/master.m3u8",
    "hls/vid.m3u8",
    "hls/aud.m3u8",
    "hls/vid-0.ts",
    "hls/vid-1.ts",
    "hls/aud-0.ts",
    "hls/aud-1.ts",
    "hls-broken/master.m3u8",
    "direct/video-only.mp4",
    "direct/audio-only.m4a",
    "page/video-only.html",
]

ENDPOINTS = [
    "/hls/master.m3u8",
    "/hls/vid.m3u8",
    "/hls/aud.m3u8",
    "/hls/vid-0.ts",
    "/hls/vid-1.ts",
    "/hls/aud-0.ts",
    "/hls/aud-1.ts",
    "/hls-broken/master.m3u8",
    "/hls-broken/aud-missing.m3u8",
    "/direct/video-only.mp4",
    "/direct/audio-only.m4a",
    "/direct/referer-403.mp4",
    "/page/video-only.html",
]


# ---------------------------------------------------------------------------
# Fixture generation
# ---------------------------------------------------------------------------


def find_ffmpeg(explicit: str | None = None) -> str | None:
    """Return the first usable ffmpeg path, or None."""
    candidates = ([explicit] if explicit else []) + FFMPEG_CANDIDATES
    for candidate in candidates:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def _run_ffmpeg(ffmpeg: str, args: list[str]) -> None:
    cmd = [ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + args
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        tail = (proc.stderr or proc.stdout or "").strip().splitlines()[-8:]
        raise RuntimeError(
            "ffmpeg failed while generating fixtures:\n  "
            + " ".join(cmd)
            + "\n"
            + "\n".join(tail)
        )


def _write_text(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def generate_fixtures(root: str, ffmpeg: str) -> None:
    """(Re)generate every fixture file under `root` with real media bytes."""
    root = os.path.abspath(root)
    hls_dir = os.path.join(root, "hls")
    direct_dir = os.path.join(root, "direct")
    page_dir = os.path.join(root, "page")
    for d in (hls_dir, direct_dir, page_dir, os.path.join(root, "hls-broken")):
        os.makedirs(d, exist_ok=True)

    # Two tiny video-only MPEG-TS segments (2 s each, 0x47 sync byte).
    for name, color in (("vid-0.ts", "testsrc"), ("vid-1.ts", "testsrc2")):
        _run_ffmpeg(
            ffmpeg,
            [
                "-f", "lavfi", "-i", f"{color}=duration=2:size=320x180:rate=25",
                "-an",
                "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
                "-g", "25", "-movflags", "+faststart",
                "-f", "mpegts",
                os.path.join(hls_dir, name),
            ],
        )

    # Two tiny audio-only MPEG-TS segments (different tones so concatenation is
    # observable if a test wants to check continuity).
    for name, freq in (("aud-0.ts", "440"), ("aud-1.ts", "660")):
        _run_ffmpeg(
            ffmpeg,
            [
                "-f", "lavfi", "-i", f"sine=frequency={freq}:duration=2:sample_rate=44100",
                "-vn",
                "-c:a", "aac", "-b:a", "64k",
                "-f", "mpegts",
                os.path.join(hls_dir, name),
            ],
        )

    # Direct video-only MP4 (H.264, no audio stream at all).
    _run_ffmpeg(
        ffmpeg,
        [
            "-f", "lavfi", "-i", "testsrc2=duration=2:size=320x180:rate=25",
            "-an",
            "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
            "-g", "25", "-movflags", "+faststart",
            os.path.join(direct_dir, "video-only.mp4"),
        ],
    )

    # Direct audio-only M4A (AAC, no video stream at all).
    _run_ffmpeg(
        ffmpeg,
        [
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=44100",
            "-vn",
            "-c:a", "aac", "-b:a", "64k", "-movflags", "+faststart",
            os.path.join(direct_dir, "audio-only.m4a"),
        ],
    )

    _write_text(os.path.join(hls_dir, "master.m3u8"), HLS_MASTER)
    _write_text(os.path.join(hls_dir, "vid.m3u8"), HLS_VIDEO_PLAYLIST)
    _write_text(os.path.join(hls_dir, "aud.m3u8"), HLS_AUDIO_PLAYLIST)
    _write_text(os.path.join(root, "hls-broken", "master.m3u8"), HLS_BROKEN_MASTER)
    _write_text(os.path.join(page_dir, "video-only.html"), PAGE_VIDEO_ONLY)


def missing_fixture_files(root: str) -> list[str]:
    root = os.path.abspath(root)
    missing = []
    for rel in FIXTURE_FILES:
        path = os.path.join(root, rel)
        if not os.path.isfile(path) or os.path.getsize(path) <= 0:
            missing.append(rel)
    return missing


def ensure_fixtures(root: str, ffmpeg: str | None) -> bool:
    """Make sure `root` contains a complete fixture set.

    Returns True when the fixtures are ready, False when they could not be
    produced because ffmpeg is unavailable. A complete pre-built `--root` is
    reused as-is (even without ffmpeg on PATH).
    """
    missing = missing_fixture_files(root)
    if missing:
        if not ffmpeg:
            sys.stderr.write(
                "[media-fixture] ffmpeg not found and fixtures are incomplete "
                f"(missing: {', '.join(missing)}).\n"
                "[media-fixture] install ffmpeg (e.g. `brew install ffmpeg`) "
                "or pass --root with a complete pre-built fixture directory.\n"
            )
            return False
        sys.stderr.write(
            f"[media-fixture] generating {len(missing)} fixture file(s) with {ffmpeg}\n"
        )
        generate_fixtures(root, ffmpeg)
    missing = missing_fixture_files(root)
    if missing:
        sys.stderr.write(
            "[media-fixture] fixture generation incomplete, still missing: "
            + ", ".join(missing)
            + "\n"
        )
        return False
    return True


# ---------------------------------------------------------------------------
# HTTP server
# ---------------------------------------------------------------------------


def content_type_for(path: str) -> str:
    _, ext = os.path.splitext(path)
    return CONTENT_TYPES.get(ext.lower(), "application/octet-stream")


def parse_single_range(header: str | None, size: int):
    """Parse a single `Range: bytes=...` header.

    Returns (start, end) for a satisfiable range, None when the header should
    be ignored (absent/unsupported), or the string "invalid" for a 416.
    """
    if not header:
        return None
    value = header.strip()
    if not value.lower().startswith("bytes="):
        return None
    spec = value[6:].strip()
    if "," in spec or "-" not in spec:
        return None
    start_text, _, end_text = spec.partition("-")
    try:
        if start_text == "":
            suffix = int(end_text)
            if suffix <= 0 or size == 0:
                return "invalid"
            return (max(0, size - suffix), size - 1)
        start = int(start_text)
        if start < 0 or start >= size:
            return "invalid"
        end = int(end_text) if end_text else size - 1
    except ValueError:
        return None
    if end < start:
        return "invalid"
    return (start, min(end, size - 1))


class MediaFixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "IDMMediaFixture/1.0"

    # -- logging ---------------------------------------------------------
    def log_message(self, fmt, *args):  # noqa: D401 - BaseHTTPRequestHandler API
        sys.stderr.write("[media-fixture] " + (fmt % args) + "\n")
        sys.stderr.flush()

    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler API
        self._serve(send_body=True)

    def do_HEAD(self):  # noqa: N802 - BaseHTTPRequestHandler API
        self._serve(send_body=False)

    # -- helpers ---------------------------------------------------------
    def _send(self, status: int, body: bytes, content_type: str, extra_headers=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Accept-Ranges", "bytes")
        for name, value in (extra_headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self._body = body

    def _write_body(self):
        body = getattr(self, "_body", b"")
        if not body:
            return
        try:
            self.wfile.write(body)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _serve(self, send_body: bool):
        path = unquote(urlsplit(self.path).path or "/")
        if path == "/":
            payload = json.dumps(
                {
                    "status": "ok",
                    "fixture": "internet-downloader-media",
                    "endpoints": ENDPOINTS,
                },
                ensure_ascii=False,
            ).encode("utf-8")
            self._send(200, payload, "application/json")
            if send_body:
                self._write_body()
            return

        # Anti-hotlink regression fixture: 403 without a Referer header,
        # otherwise serve the bytes of direct/video-only.mp4.
        if path == "/direct/referer-403.mp4" and not self.headers.get("Referer"):
            body = b"403 forbidden: missing Referer header\n"
            self.send_response(403)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if send_body:
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass
            return
        if path == "/direct/referer-403.mp4":
            path = "/direct/video-only.mp4"

        root = self.server.fixture_root  # type: ignore[attr-defined]
        rel = path.lstrip("/")
        full = os.path.realpath(os.path.join(root, rel))
        root_real = os.path.realpath(root)
        if full != root_real and not full.startswith(root_real + os.sep):
            self._send(404, b"404 not found\n", "text/plain; charset=utf-8")
            if send_body:
                self._write_body()
            return

        if not os.path.isfile(full):
            self._send(404, b"404 not found\n", "text/plain; charset=utf-8")
            if send_body:
                self._write_body()
            return

        try:
            with open(full, "rb") as f:
                data = f.read()
        except OSError:
            self._send(500, b"500 read error\n", "text/plain; charset=utf-8")
            if send_body:
                self._write_body()
            return

        ctype = content_type_for(full)
        total = len(data)
        byte_range = parse_single_range(self.headers.get("Range"), total)

        if byte_range == "invalid":
            self.send_response(416)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", "0")
            self.send_header("Content-Range", f"bytes */{total}")
            self.send_header("Accept-Ranges", "bytes")
            self.end_headers()
            return

        if byte_range is not None:
            start, end = byte_range
            chunk = data[start : end + 1]
            self._send(
                206,
                chunk,
                ctype,
                {
                    "Content-Range": f"bytes {start}-{end}/{total}",
                    "Cache-Control": "no-cache",
                },
            )
        else:
            self._send(200, data, ctype, {"Cache-Control": "no-cache"})

        if send_body:
            self._write_body()


class MediaFixtureServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, fixture_root: str):
        super().__init__(address, MediaFixtureHandler)
        self.fixture_root = fixture_root


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Offline media fixture server for Internet Downloader tests."
    )
    parser.add_argument(
        "--port", type=int, default=0,
        help="TCP port to listen on (0 = ephemeral, default 0)",
    )
    parser.add_argument(
        "--root", type=str, default=None,
        help="Fixture directory to reuse/generate (default: a fresh temp dir)",
    )
    parser.add_argument(
        "--ffmpeg", type=str, default=None,
        help="Path to ffmpeg (default: auto-detect /opt/homebrew/bin/ffmpeg)",
    )
    parser.add_argument(
        "--quiet", action="store_true",
        help="Suppress the request log on stderr",
    )
    args = parser.parse_args(argv)

    ffmpeg = find_ffmpeg(args.ffmpeg)
    if args.root:
        root = os.path.abspath(args.root)
        os.makedirs(root, exist_ok=True)
    else:
        root = tempfile.mkdtemp(prefix="idm-media-fixtures-")

    try:
        ready = ensure_fixtures(root, ffmpeg)
    except RuntimeError as exc:
        sys.stderr.write(f"[media-fixture] {exc}\n")
        return 2
    if not ready:
        return 2

    if args.quiet:
        MediaFixtureHandler.log_message = lambda self, fmt, *a: None  # type: ignore[method-assign]

    try:
        server = MediaFixtureServer((HOST, args.port), root)
    except OSError as exc:
        sys.stderr.write(f"[media-fixture] cannot bind {HOST}:{args.port}: {exc}\n")
        return 2

    stop_event = threading.Event()

    def _handle_signal(signum, _frame):
        sys.stderr.write(f"[media-fixture] received signal {signum}, shutting down\n")
        sys.stderr.flush()
        stop_event.set()

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    serving = threading.Thread(
        target=server.serve_forever, name="media-fixture-serve", daemon=True
    )
    serving.start()

    sys.stderr.write(f"[media-fixture] root={root}\n")
    if ffmpeg is None:
        sys.stderr.write(
            "[media-fixture] ffmpeg not found; serving pre-built fixtures only\n"
        )
    sys.stderr.write(
        f"[media-fixture] listening on http://{HOST}:{server.server_port}\n"
    )
    sys.stderr.flush()

    # Protocol with the test harness: exactly one JSON line on stdout.
    sys.stdout.write(json.dumps({"port": server.server_port}) + "\n")
    sys.stdout.flush()

    try:
        stop_event.wait()
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()
        server.server_close()
        serving.join(timeout=5)
        sys.stderr.write("[media-fixture] stopped\n")
        sys.stderr.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
