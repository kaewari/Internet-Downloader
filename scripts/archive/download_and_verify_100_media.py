#!/usr/bin/env python3
"""
[DEPRECATED] Trình tải/kiểm chứng 100 nguồn media — **đã thay bằng harness chung**.

Bản cũ tải bằng `urllib` nên **không kiểm chứng engine của app** và cần ~9,8 GB
mỗi lần chạy. Nay dùng chung `test-app-pipeline` / `test-100-sources`, với:

  * danh sách nguồn duy nhất: `scripts/media_sources_100.json`
  * tải bằng `MediaURLResolver` + `HTTPRangeDownloader` (mô hình head+tail)
  * kiểm chứng magic byte (`FileTypeDetector`) + `ffprobe` + decode
  * tự làm mới URL chết và báo cáo PASS/FAIL/SKIP trung thực

Cách dùng mới:

    python3 scripts/verify_media_sources.py --tier quick     # báo cáo đầy đủ
    swift run test-100-sources --tier deep                   # chạy trực tiếp

Lệnh này giữ lại để tương thích; nó chuyển tiếp sang harness chung.
"""

import os
import subprocess
import sys

SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPTS_DIR, ".."))


def main():
    print("[deprecated] Dùng scripts/verify_media_sources.py (harness chung của app).", file=sys.stderr)
    cmd = [sys.executable, os.path.join(SCRIPTS_DIR, "verify_media_sources.py")] + sys.argv[1:]
    return subprocess.call(cmd, cwd=PROJECT_ROOT)


if __name__ == "__main__":
    sys.exit(main())
