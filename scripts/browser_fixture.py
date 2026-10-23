#!/usr/bin/env python3
"""Generate public synthetic fixtures and serve them on loopback for Chrome acceptance."""
import argparse
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess


def find_ffmpeg():
    """Resolve ffmpeg: ENV FFMPEG -> /opt/homebrew -> /usr/local -> which. None when missing."""
    override = os.environ.get("FFMPEG")
    candidates = [c for c in [override, "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] if c]
    for candidate in candidates:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return shutil.which("ffmpeg")

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--port', type=int, default=8810)
parser.add_argument('--prepare-only', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
folder = root / '.runtime/browser-fixture'
folder.mkdir(parents=True, exist_ok=True)
shutil.copy2(root / 'Tests/Fixtures/browser_save.html', folder / 'index.html')
(folder / 'document.bin').write_bytes((b'Internet Downloader browser fixture\n' * 20000)[:524326])
ffmpeg = find_ffmpeg()
if ffmpeg is None:
    raise SystemExit("ffmpeg not found (set FFMPEG or install ffmpeg via Homebrew)")
subprocess.run([ffmpeg, '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=10', '-t', '6', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-y', str(folder / 'video.mp4')], check=True)
expected = {name: {'bytes': (folder / name).stat().st_size, 'sha256': hashlib.sha256((folder / name).read_bytes()).hexdigest()} for name in ['video.mp4', 'document.bin']}
(folder / 'expected.json').write_text(json.dumps(expected, indent=2))
print(json.dumps({'url': f'http://127.0.0.1:{args.port}/', 'expected': str(folder / 'expected.json')}), flush=True)
if not args.prepare_only:
    class Handler(SimpleHTTPRequestHandler):
        def __init__(self, *items, **options):
            super().__init__(*items, directory=str(folder), **options)
    ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
