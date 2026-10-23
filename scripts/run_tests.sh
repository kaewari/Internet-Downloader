#!/bin/bash
set -euo pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
cd "$DIR"

echo "==> 0. Checking version consistency (VERSION/AppVersion/manifest)..."
bash scripts/check_versions.sh --no-dist

echo "=========================================================="
echo "  Internet Downloader for macOS - Comprehensive Verification"
echo "=========================================================="

echo "==> 1. Building all SPM products (Core, Native Host, Desktop App, test-app-pipeline)..."
swift build
swift build --product test-app-pipeline

echo "==> 2. Running all Unit & Integration Tests..."
swift test --verbose

echo "==> 3. Testing browser extension protocol..."
node --test Tests/ExtensionTests/*.test.cjs
node --check Extension/background.js
node --check Extension/content.js
node --check Extension/telegram.js
node --check Extension/browser-transfer.js

echo "==> 4. Running media validator test suites..."
python3 scripts/test_media_validator.py
python3 scripts/test_challenger_media_validator.py

echo "==> 5. Running platform routing challenger tests..."
python3 scripts/test_challenger_platform_routing.py

echo "==> 6. Running offline media fixture server tests (HLS audio + video-only MP4)..."
python3 scripts/test_media_server_fixture.py

echo "==> 7. Verifying Browser Extension Structure..."
if [ ! -f "Extension/manifest.json" ]; then
    echo "ERROR: Missing Extension/manifest.json"
    exit 1
fi
if [ ! -f "Extension/background.js" ]; then
    echo "ERROR: Missing Extension/background.js"
    exit 1
fi
if [ ! -f "Extension/content.js" ]; then
    echo "ERROR: Missing Extension/content.js"
    exit 1
fi
if [ ! -f "Extension/icons/icon128.png" ]; then
    echo "ERROR: Missing Extension icons"
    exit 1
fi
if [ ! -f "scripts/live_platform_sources.json" ]; then
    echo "ERROR: Missing scripts/live_platform_sources.json (live test matrix config)"
    exit 1
fi
if [ ! -f "scripts/media_sources_100.json" ]; then
    echo "ERROR: Missing scripts/media_sources_100.json (media source catalog)"
    exit 1
fi

echo "==> 8. Validating media source catalog (offline constraints)..."
python3 - <<'PY'
import json, os, sys, urllib.parse

path = "scripts/media_sources_100.json"
with open(path, "r", encoding="utf-8") as f:
    catalog = json.load(f)
cases = [c for c in catalog.get("cases", []) if c.get("status") != "retired"]

errors = []
if len(cases) < 120:
    errors.append(f"chỉ có {len(cases)} mục (cần ≥ 120)")
hosts = {urllib.parse.urlparse(c.get("url", "")).hostname for c in cases}
if len(hosts) < 100:
    errors.append(f"chỉ có {len(hosts)} host độc lập (cần ≥ 100)")
nsfw = [c for c in cases if "nsfw" in c.get("tags", [])]
if len(nsfw) < 25:
    errors.append(f"chỉ có {len(nsfw)} nguồn NSFW (cần ≥ 25)")
ids, urls = set(), set()
for c in cases:
    cid = c.get("id", "")
    if cid in ids:
        errors.append(f"id trùng: {cid}")
    ids.add(cid)
    url = c.get("url", "")
    if url in urls:
        errors.append(f"URL trùng: {url}")
    urls.add(url)
    if not url.startswith("http"):
        errors.append(f"URL không hợp lệ ở {cid}")
    if c.get("kind") not in ("video", "audio", "image", "any"):
        errors.append(f"kind không hợp lệ ở {cid}: {c.get('kind')}")
    if c.get("access") not in ("public-sample", "public-nsfw", "requires-auth"):
        errors.append(f"access không hợp lệ ở {cid}: {c.get('access')}")

if errors:
    print("ERROR: Danh sách nguồn media không hợp lệ:")
    for e in errors[:20]:
        print("  -", e)
    sys.exit(1)
print(f"  OK — {len(cases)} mục | {len(hosts)} host | {len(nsfw)} nguồn NSFW")
PY

echo "=========================================================="
echo "  OFFLINE CHECKS PASSED"
echo "  Live media matrix (app pipeline) is a separate step:"
echo "    python3 scripts/verify_live_media_sources.py"
echo "  Live 100+ media sources (app pipeline) is also separate:"
echo "    python3 scripts/verify_media_sources.py --tier quick"
echo "  Chrome/Telegram acceptance is also separate."
echo "=========================================================="
