#!/usr/bin/env python3
"""
Kiểm thử 100+ nguồn media thật bằng **engine của app** và sinh báo cáo.

Gọi target Swift `test-app-pipeline` với danh sách nguồn
(`scripts/media_sources_100.json`): mỗi nguồn được tải bằng
`MediaURLResolver` + `HTTPRangeDownloader` (mô hình head+tail → file thưa có
đúng kích thước nguồn) rồi kiểm chứng bằng `FileTypeDetector` + `ffprobe`.

    python3 scripts/verify_media_sources.py --tier quick
    python3 scripts/verify_media_sources.py --tier deep --exclude-tag nsfw

Báo cáo: `docs/100_media_sources_report.md` (+ JSON thô).
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter

SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPTS_DIR, ".."))
DEFAULT_CATALOG = os.path.join(SCRIPTS_DIR, "media_sources_100.json")
DEFAULT_REPORT = os.path.join(PROJECT_ROOT, "docs", "100_media_sources_report.md")

BROWSER_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"
)


def format_bytes(n):
    if not n:
        return "0 B"
    if n < 1024:
        return f"{n} B"
    if n < 1024 ** 2:
        return f"{n / 1024:.1f} KB"
    if n < 1024 ** 3:
        return f"{n / 1024 ** 2:.1f} MB"
    return f"{n / 1024 ** 3:.2f} GB"


def build_binary():
    binary = os.path.join(PROJECT_ROOT, ".build", "debug", "test-app-pipeline")
    if os.path.exists(binary):
        return binary
    print("==> Đang build test-app-pipeline…")
    build = subprocess.run(
        ["swift", "build", "--product", "test-app-pipeline"],
        cwd=PROJECT_ROOT, capture_output=True, text=True,
    )
    if build.returncode != 0:
        print(build.stdout[-1500:], file=sys.stderr)
        print(build.stderr[-1500:], file=sys.stderr)
        return None
    return binary


def run_harness(args, catalog, json_out, dest):
    binary = build_binary()
    if not binary:
        return None
    cmd = [
        binary,
        "--config", catalog,
        "--output", json_out,
        "--tier", args.tier,
        "--concurrency", str(args.concurrency),
        "--dest", dest,
    ]
    if args.head_bytes:
        cmd += ["--head-bytes", str(args.head_bytes)]
    if args.tail_bytes:
        cmd += ["--tail-bytes", str(args.tail_bytes)]
    for tag in args.exclude_tag:
        cmd += ["--exclude-tag", tag]
    for host in args.exclude_host:
        cmd += ["--exclude-host", host]
    if args.keep_files:
        cmd += ["--keep-files"]
    print("==> " + " ".join(cmd))
    proc = subprocess.run(cmd, cwd=PROJECT_ROOT)
    if not os.path.exists(json_out):
        return None
    with open(json_out, "r", encoding="utf-8") as f:
        return json.load(f)


def crosscheck(url, timeout=20):
    """Dò lại URL bằng HTTP để phân biệt lỗi app với nguồn đã chết."""
    req = urllib.request.Request(url, headers={"User-Agent": BROWSER_UA, "Range": "bytes=0-1023"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return "Có" if resp.status in (200, 206) else f"HTTP {resp.status}"
    except urllib.error.HTTPError as e:
        return f"HTTP {e.code}"
    except Exception as e:
        return type(e).__name__


def build_report(outcomes, catalog, generated_at, crosscheck_map, tier):
    total = len(outcomes)
    passed = sum(1 for o in outcomes if o["status"] == "PASS")
    failed = sum(1 for o in outcomes if o["status"] == "FAIL")
    skipped = sum(1 for o in outcomes if o["status"] == "SKIP")
    hosts = {o.get("finalHost") or o["requestedURL"] for o in outcomes}
    hosts.discard("")
    nsfw = [o for o in outcomes if "nsfw" in (o.get("tags") or [])]
    kinds = Counter(o.get("kind") for o in outcomes)
    tag_counter = Counter(t for o in outcomes for t in (o.get("tags") or []))

    lines = [
        "# Báo cáo kiểm thử nguồn media (100+ nguồn thật)",
        "",
        f"**Generated At**: `{generated_at}`  ",
        f"**Tầng**: `{tier}`  ",
        f"**Kết quả**: **{passed} PASS / {failed} FAIL / {skipped} SKIP** (tổng {total})  ",
        "",
        "Mỗi nguồn được tải bằng **engine thật của app** (`MediaURLResolver` + "
        "`HTTPRangeDownloader`), mô hình **head + tail** nên file thưa có đúng kích "
        "thước nguồn và `ffprobe` đọc được cả `moov`/cues ở cuối. Kiểm chứng: magic byte "
        "(`FileTypeDetector`) + `ffprobe` stream + kích thước > 0.",
        "",
        "## Tổng hợp",
        "",
        "| Chỉ số | Giá trị |",
        "|---|---|",
        f"| Tổng ca | {total} |",
        f"| PASS | {passed} |",
        f"| FAIL | {failed} |",
        f"| SKIP | {skipped} |",
        f"| Tỉ lệ PASS (không tính SKIP) | {(passed / max(passed + failed, 1) * 100):.1f}% |",
        f"| Host độc lập | {len(hosts)} |",
        f"| Nguồn NSFW | {len(nsfw)} |",
        "",
        "### Theo loại media",
        "",
        "| Loại | Số ca | PASS | FAIL | SKIP |",
        "|---|---|---|---|---|",
    ]
    for kind, count in sorted(kinds.items(), key=lambda kv: -kv[1]):
        subset = [o for o in outcomes if o.get("kind") == kind]
        lines.append(
            f"| {kind} | {count} | {sum(1 for o in subset if o['status'] == 'PASS')} | "
            f"{sum(1 for o in subset if o['status'] == 'FAIL')} | "
            f"{sum(1 for o in subset if o['status'] == 'SKIP')} |"
        )

    lines += [
        "",
        "### Theo tag",
        "",
        "| Tag | Số ca |",
        "|---|---|",
    ]
    for tag, count in sorted(tag_counter.items(), key=lambda kv: -kv[1]):
        lines.append(f"| {tag} | {count} |")

    lines += [
        "",
        "## Chi tiết từng nguồn",
        "",
        "| # | Host | Loại | Tag | URL (yêu cầu → thực tế) | Kích thước nguồn | Đã tải | Thời gian | Streams | Kết quả | Ghi chú |",
        "|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for index, o in enumerate(outcomes, start=1):
        host = o.get("finalHost") or "—"
        req = o.get("requestedURL") or ""
        res = o.get("resolvedURL") or req
        tags = ",".join(o.get("tags") or []) or "—"
        streams = "+".join(o.get("streams") or []) or "—"
        message = (o.get("message") or "").replace("|", "\\|")
        if len(message) > 110:
            message = message[:107] + "…"
        url_cell = f"`{req[:70]}`" if req == res else f"`{req[:52]}…` → `{res[:52]}…`"
        lines.append(
            f"| {index} | `{host}` | {o.get('kind')} | {tags} | {url_cell} | "
            f"{format_bytes(o.get('sourceSizeBytes', 0))} | {format_bytes(o.get('downloadedBytes', 0))} | "
            f"{o.get('durationSeconds', 0):.1f}s | {streams} | **{o['status']}** | {message} |"
        )

    failures = [o for o in outcomes if o["status"] == "FAIL"]
    if failures:
        lines += [
            "",
            "## Ca FAIL — đối chiếu để chứng minh lỗi không thuộc app",
            "",
            "| # | Host | Thông báo | URL còn sống? | Kết luận |",
            "|---|---|---|---|---|",
        ]
        for o in failures:
            state = crosscheck_map.get(o["id"], "không rõ")
            verdict = ("URL còn sống → **cần sửa app**" if state.startswith("Có")
                       else "URL đã chết/hết hạn → không phải lỗi app")
            lines.append(
                f"| `{o.get('finalHost') or o['id']}` | {o.get('id')} | "
                f"{(o.get('message') or '')[:90].replace('|', '/')} | {state} | {verdict} |"
            )

    skipped = [o for o in outcomes if o["status"] == "SKIP"]
    if skipped:
        def family_of(o):
            host = o.get("finalHost") or urllib.parse.urlparse(o.get("requestedURL") or "").hostname or ""
            parts = host.lower().split(".")
            return ".".join(parts[-2:]) if len(parts) >= 2 else (host or "?")
        fam_counts = Counter(family_of(o) for o in skipped)
        lines += [
            "",
            "## Ca SKIP (nguồn không dùng được — không tính là PASS)",
            "",
            "### Theo họ host",
            "",
            "| Họ host | Số ca SKIP |",
            "|---|---|",
        ]
        for fam, count in fam_counts.most_common(10):
            lines.append(f"| `{fam}` | {count} |")
        lines += [
            "",
            "> Nhiều ca SKIP cùng lúc thường do **một dịch vụ CDN không phản hồi** "
            "(mạng chặn/rate-limit), không phải lỗi của app. Có thể chạy lại sau, "
            "hoặc bỏ qua nhóm đó bằng `--exclude-host <tên miền>`.",
            "",
            "| # | Host | Lý do |",
            "|---|---|---|",
        ]
        for o in skipped:
            host = o.get("finalHost") or urllib.parse.urlparse(o.get("requestedURL") or "").hostname or "—"
            lines.append(
                f"| `{host}` | {o.get('id')} | "
                f"{(o.get('message') or '')[:140].replace('|', '/')} |"
            )

    lines += [
        "",
        "## Ghi chú",
        "",
        "- `SKIP` = nguồn không truy cập được (URL hết hạn, cần đăng nhập, bị policy chặn) — **không tính là PASS**.",
        "- Nguồn NSFW được đánh dấu bằng tag `nsfw`; chạy `--exclude-tag nsfw` để không chạy/nhìn thấy nhóm này.",
        "- Bộ test không bao giờ gửi cookie/tài khoản: mục `access: requires-auth` bị bỏ qua.",
        "- Danh sách nguồn: `scripts/media_sources_100.json`; làm mới: "
        "`python3 scripts/refresh_media_sources.py refresh --update-config`.",
        "",
    ]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description="Kiểm thử 100+ nguồn media qua engine của app")
    parser.add_argument("--catalog", default=DEFAULT_CATALOG)
    parser.add_argument("--tier", default="quick", choices=["smoke", "quick", "deep"])
    parser.add_argument("--concurrency", type=int, default=8)
    parser.add_argument("--output", default=DEFAULT_REPORT, help="Đường dẫn báo cáo markdown")
    parser.add_argument("--json-output", default=os.path.join(PROJECT_ROOT, "media_sources_results.json"))
    parser.add_argument("--dest", default=os.path.join(PROJECT_ROOT, "test_downloads", "media_sources"))
    parser.add_argument("--head-bytes", type=int, default=0)
    parser.add_argument("--tail-bytes", type=int, default=0)
    parser.add_argument("--exclude-tag", action="append", default=[])
    parser.add_argument("--exclude-host", action="append", default=[],
                        help="Bỏ nguồn có host chứa chuỗi này (khi một CDN sập)")
    parser.add_argument("--keep-files", action="store_true")
    parser.add_argument("--no-crosscheck", action="store_true")
    parser.add_argument("--from-results", default=None,
                        help="Dựng lại báo cáo từ file kết quả có sẵn (không tải lại)")
    args = parser.parse_args()

    if not os.path.exists(args.catalog):
        print(f"Không tìm thấy danh sách nguồn: {args.catalog}", file=sys.stderr)
        return 2

    os.makedirs(os.path.dirname(args.json_output) or ".", exist_ok=True)
    os.makedirs(args.dest, exist_ok=True)

    outcomes = None
    if args.from_results and os.path.exists(args.from_results):
        print(f"==> Dựng lại báo cáo từ {args.from_results} (không tải lại)")
        with open(args.from_results, "r", encoding="utf-8") as f:
            outcomes = json.load(f)
    else:
        outcomes = run_harness(args, args.catalog, args.json_output, args.dest)
    if outcomes is None:
        print("Không chạy được harness.", file=sys.stderr)
        return 2

    crosscheck_map = {}
    if not args.no_crosscheck:
        for o in outcomes:
            if o["status"] == "FAIL":
                print(f"==> Đối chiếu: {o.get('id')}")
                crosscheck_map[o["id"]] = crosscheck(o["requestedURL"])

    report = build_report(
        outcomes, args.catalog,
        time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        crosscheck_map, args.tier,
    )
    os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        f.write(report)
    print(f"\nBáo cáo: {args.output}")

    failed = sum(1 for o in outcomes if o["status"] == "FAIL")
    passed = sum(1 for o in outcomes if o["status"] == "PASS")
    skipped = sum(1 for o in outcomes if o["status"] == "SKIP")
    print(f"Tổng: {passed} PASS / {failed} FAIL / {skipped} SKIP / {len(outcomes)} ca")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
