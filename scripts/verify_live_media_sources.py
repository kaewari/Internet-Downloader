#!/usr/bin/env python3
"""
Live Media Sources Verification Runner — chạy pipeline CỦA APP, không phải yt-dlp.

Vấn đề mà bản cũ gây ra: runner cũ tải bằng `yt-dlp`/`urllib` trực tiếp nên nó
**không hề kiểm chứng app** — mọi lỗi trong engine của app (nổi tiếng, ghép file,
…) đều bị che. Bản này gọi `test-app-pipeline` (target SPM) để đi đúng đường:

    URL trang → MediaURLResolver.resolve → tải (range/HLS) → ghép nếu cần → ffprobe

Kiểm chứng bắt buộc:
  * HTTP 200 và kích thước file > 0 byte
  * Cấu trúc container hợp lệ (ffprobe đọc được stream)
  * Với nguồn có âm thanh: file cuối phải có CẢ luồng video VÀ luồng audio
    (đây là kiểm chứng bắt lỗi "tải YouTube về mất tiếng")

Báo cáo sinh ra (`test_matrix_report.md`) ghi rõ:
  * URL đã yêu cầu và URL thực sự được tải
  * Phương pháp (app-native / yt-dlp cross-check)
  * Trạng thái PASS / FAIL / SKIP (nguồn hết hạn ≠ PASS)

Các URL nguồn nằm trong `scripts/live_platform_sources.json` (URL trang thật, không
hardcode URL CDN có chữ ký hết hạn).
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time

SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPTS_DIR, ".."))
DEFAULT_CONFIG = os.path.join(SCRIPTS_DIR, "live_platform_sources.json")

YT_DLP_CANDIDATES = [
    "/Library/Frameworks/Python.framework/Versions/3.14/bin/yt-dlp",
    "/opt/homebrew/bin/yt-dlp",
    "/usr/local/bin/yt-dlp",
    shutil.which("yt-dlp"),
]


def get_binary(candidates):
    for p in candidates:
        if p and os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


def format_bytes(num_bytes):
    if num_bytes is None or num_bytes < 0:
        return "N/A"
    if num_bytes < 1024:
        return f"{num_bytes} B"
    if num_bytes < 1024 * 1024:
        return f"{num_bytes / 1024:.1f} KB"
    if num_bytes < 1024 * 1024 * 1024:
        return f"{num_bytes / 1024 / 1024:.1f} MB"
    return f"{num_bytes / 1024 / 1024 / 1024:.2f} GB"


# ---------------------------------------------------------------------------
# Audio enforcement
# ---------------------------------------------------------------------------
#
# Ma trận này tồn tại để bắt lỗi "video tải về mất tiếng". Vì vậy:
#   * mọi ca có expect_video=true phải có expect_audio tường minh trong config;
#   * ca có expect_audio=true mà file cuối KHÔNG có luồng audio thì phải FAIL,
#     kể cả khi pipeline báo PASS (phòng thủ nhiều lớp — báo cáo không được
#     PASS im lặng một file không tiếng).
#
# Pipeline JSON có thể kèm `audioState`/`audio_state` (do Lead thêm vào
# test-app-pipeline) — giá trị này được in vào báo cáo khi có.

AUDIO_MISSING_STATES = {
    "missing", "none", "absent", "no_audio", "noaudio", "video_only",
    "video-only", "not_present", "unavailable", "khong_co", "không_có",
}
AUDIO_PRESENT_STATES = {
    "present", "ok", "muxed", "merged", "available", "has_audio",
    "included", "separate", "combined",
}


def load_case_expectations(config_path):
    """id -> case dict từ live_platform_sources.json (best effort)."""
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            config = json.load(f)
    except (OSError, ValueError):
        return {}
    cases = config.get("cases", []) if isinstance(config, dict) else []
    return {
        case["id"]: case
        for case in cases
        if isinstance(case, dict) and case.get("id")
    }


def audio_state_of(result):
    """Trả về audioState/audio_state của kết quả pipeline (nếu có)."""
    for key in ("audioState", "audio_state"):
        if key in result and result[key] is not None:
            return result[key]
    return None


def audio_state_means_missing(value):
    if isinstance(value, bool):
        return not value
    if isinstance(value, str):
        normalized = value.strip().lower().replace(" ", "_")
        return normalized in AUDIO_MISSING_STATES or "missing" in normalized
    return False


def audio_state_means_present(value):
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        normalized = value.strip().lower().replace(" ", "_")
        return normalized in AUDIO_PRESENT_STATES
    return False


def enforce_audio_expectations(results, cases_by_id):
    """Ép luật audio lên kết quả pipeline.

    Trả về danh sách id đã bị hạ PASS -> FAIL vì thiếu audio. Cũng gắn
    `expect_audio` vào từng kết quả để báo cáo/JSON cùng một nguồn sự thật.
    """
    forced_failures = []
    for result in results:
        case = cases_by_id.get(result.get("id"))
        if not case:
            continue

        expect_video = bool(case.get("expect_video", True))
        expect_audio = case.get("expect_audio")
        if expect_audio is None:
            # Config cũ/mới thiếu field: video thì mặc định phải có audio.
            expect_audio = expect_video
        expect_audio = bool(expect_audio)
        result["expect_audio"] = expect_audio

        if not expect_audio or result.get("status") == "SKIP":
            continue
        if (result.get("sizeBytes") or 0) <= 0:
            continue  # không có file: đã FAIL vì lý do khác

        streams = result.get("streams") or []
        state = audio_state_of(result)
        audio_ok = "audio" in streams or audio_state_means_present(state)
        audio_broken = audio_state_means_missing(state)

        if audio_ok and not audio_broken:
            continue

        detail = "thiếu luồng audio (bắt buộc vì expect_audio=true)"
        if state is not None:
            detail += f"; audioState={state!r}"
        elif streams:
            detail += f"; streams hiện có: {','.join(streams)}"

        status_before = result.get("status")
        message = (result.get("message") or "").strip()
        if status_before != "FAIL":
            result["status"] = "FAIL"
            forced_failures.append(result.get("id"))
            if message.upper().startswith("OK"):
                message = ""
        if detail not in message:
            result["message"] = f"{message}; {detail}" if message else detail

    return forced_failures



def run_app_pipeline(config_path, output_json, platform=None, timeout=240, dest=None):
    """Chạy target Swift `test-app-pipeline` (pipeline thật của app)."""
    binary = os.path.join(PROJECT_ROOT, ".build", "debug", "test-app-pipeline")
    if not os.path.exists(binary):
        print("==> Đang build test-app-pipeline...")
        build = subprocess.run(
            ["swift", "build", "--product", "test-app-pipeline"],
            cwd=PROJECT_ROOT, capture_output=True, text=True,
        )
        if build.returncode != 0:
            print(build.stdout[-2000:])
            print(build.stderr[-2000:], file=sys.stderr)
            return None
        binary = os.path.join(PROJECT_ROOT, ".build", "debug", "test-app-pipeline")

    cmd = [
        binary,
        "--config", config_path,
        "--output", output_json,
        "--timeout", str(timeout),
    ]
    if platform:
        cmd += ["--platform", platform]
    if dest:
        cmd += ["--dest", dest]

    print(f"==> Chạy pipeline của app: {' '.join(cmd)}")
    result = subprocess.run(cmd, cwd=PROJECT_ROOT)
    if result.returncode not in (0, 1):
        return None
    if not os.path.exists(output_json):
        return None
    with open(output_json, "r", encoding="utf-8") as f:
        return json.load(f)


def ytdlp_crosscheck(url, timeout=60):
    """Đối chiếu: URL này có tải được bằng yt-dlp không (dùng để phân biệt
    lỗi của app với nguồn đã chết/hết hạn)."""
    yt_dlp = get_binary(YT_DLP_CANDIDATES)
    if not yt_dlp:
        return None
    cmd = [
        yt_dlp, "--no-playlist", "--no-warnings", "--simulate",
        "--print", "%(title)s", url,
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if proc.returncode == 0 and proc.stdout.strip():
            return True
        return False
    except subprocess.TimeoutExpired:
        return None
    except Exception:
        return None


def build_report(results, crosscheck, overall_passed, generated_at):
    total = len(results)
    passed = sum(1 for r in results if r["status"] == "PASS")
    failed = sum(1 for r in results if r["status"] == "FAIL")
    skipped = sum(1 for r in results if r["status"] == "SKIP")

    lines = [
        "# Live Media Test Matrix — Internet Downloader (pipeline của app)",
        "",
        f"**Generated At**: `{generated_at}`  ",
        f"**Overall Status**: `{'100% PASS' if overall_passed and skipped == 0 else ('PASS (có SKIP)' if overall_passed else 'FAILURES DETECTED')}` "
        f"({passed}/{total} PASS, {failed} FAIL, {skipped} SKIP)  ",
        "",
        "Nguồn kiểm thử: `scripts/live_platform_sources.json` — mỗi dòng là **URL trang thật**;",
        "app tự giải trích, tải và ghép file, sau đó `ffprobe` kiểm tra lại nội dung.",
        "",
        "**Quy tắc audio (bắt buộc)**: mọi ca `expect_video: true` phải có `expect_audio` tường minh;",
        "ca có `expect_audio: true` mà file cuối thiếu luồng audio bị tính **FAIL** — không ca video nào",
        "được PASS nếu không có tiếng (trừ ca ghi chú rõ nguồn không có audio).",
        "",
        "## Test Execution Matrix",
        "",
        "| Platform | Loại video / Stream | URL yêu cầu | URL thực tế tải | Kết quả | Streams | Audio state | Dung lượng | Thời gian |",
        "|---|---|---|---|---|---|---|---|---|",
    ]

    for r in results:
        resolved = r.get("resolvedURL") or ""
        if resolved and resolved != r["requestedURL"]:
            resolved_short = resolved.split("?")[0][:60] + "…"
        else:
            resolved_short = "—"
        streams = "+".join(r.get("streams") or []) or "—"
        audio_state = audio_state_of(r)
        audio_state_cell = "—" if audio_state is None else f"`{audio_state}`"
        lines.append(
            f"| {r['platform']} | {r.get('kind') or '—'} | `{r['requestedURL']}` | {resolved_short} | "
            f"**{r['status']}** — {r['message']} | {streams} | {audio_state_cell} | "
            f"{format_bytes(r.get('sizeBytes', 0))} | {r.get('durationSeconds', 0):.2f}s |"
        )

    if crosscheck:
        lines += [
            "",
            "## Cross-check (yt-dlp đối chiếu)",
            "",
            "| Platform | URL | yt-dlp tải được | Ghi chú |",
            "|---|---|---|---|",
        ]
        for r in results:
            if r.get("status") == "PASS":
                continue
            ok = crosscheck.get(r["id"])
            note = "URL còn sống → lỗi thuộc app" if ok is True else (
                "URL đã chết/hết hạn → không phải lỗi app" if ok is False else "không rõ"
            )
            lines.append(f"| {r['platform']} | `{r['requestedURL']}` | {'Có' if ok else ('Không' if ok is False else 'N/A')} | {note} |")

    # Checkbox chỉ được bật khi có bằng chứng thật.
    has_video = any("video" in (r.get("streams") or []) for r in results if r["status"] == "PASS")
    has_audio = any("audio" in (r.get("streams") or []) for r in results if r["status"] == "PASS")
    all_non_empty = all((r.get("sizeBytes") or 0) > 0 for r in results if r["status"] == "PASS") and passed > 0
    required_failed = [r for r in results if r["status"] == "FAIL" and r.get("required", True)]
    required_skipped = [r for r in results if r["status"] == "SKIP" and r.get("required", True)]

    # Ca yêu cầu audio mà file kết quả thiếu luồng audio: tuyệt đối không PASS.
    audio_required = [r for r in results if r.get("expect_audio")]
    audio_required_with_file = [r for r in audio_required if (r.get("sizeBytes") or 0) > 0]
    missing_audio = [
        r for r in audio_required_with_file
        if "thiếu luồng audio" in (r.get("message") or "")
    ]
    all_required_audio_ok = not missing_audio and (
        bool(audio_required_with_file)
        and all("audio" in (r.get("streams") or []) for r in audio_required_with_file if r["status"] == "PASS")
    )

    lines += [
        "",
        "## Summary",
        f"- **Total Tests Executed**: {total}",
        f"- **Successful Tests**: {passed}",
        f"- **Failed Tests**: {failed}",
        f"- **Skipped Tests**: {skipped}",
        f"- **Pass Rate**: {(passed / total * 100):.1f}%" if total else "- **Pass Rate**: N/A",
        "",
        "## Verification Criteria Compliance",
        f"- {'[x]' if all_non_empty else '[ ]'} Mọi ca PASS đều có kích thước file > 0 byte.",
        f"- {'[x]' if has_video else '[ ]'} File kết quả được `ffprobe` xác nhận có luồng video.",
        f"- {'[x]' if has_audio else '[ ]'} File kết quả được `ffprobe` xác nhận có luồng audio (không mất tiếng).",
        f"- {'[x]' if all_required_audio_ok else '[ ]'} Mọi ca `expect_audio: true` có file kết quả đều có luồng audio."
        + (
            ""
            if not missing_audio
            else " — thiếu audio: " + ", ".join(r["id"] for r in missing_audio)
        ),
        f"- {'[x]' if not required_failed else '[ ]'} Không có ca bắt buộc nào thất bại."
        + ("" if not required_failed else " — thất bại: " + ", ".join(r["id"] for r in required_failed)),
    ]
    if required_skipped:
        lines.append(
            "- [!] Ca bắt buộc bị SKIP vì nguồn không còn truy cập được (xem bảng cross-check): "
            + ", ".join(r["id"] for r in required_skipped)
        )
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description="Live media verification — app pipeline")
    parser.add_argument("--platform", type=str, default=None, help="Chỉ chạy một nền tảng")
    parser.add_argument("--timeout", type=int, default=240, help="Timeout mỗi ca (giây)")
    parser.add_argument("--config", type=str, default=DEFAULT_CONFIG, help="File cấu hình nguồn live")
    parser.add_argument("--output", type=str, default=os.path.join(PROJECT_ROOT, "test_matrix_report.md"),
                        help="Đường dẫn báo cáo markdown")
    parser.add_argument("--json-output", type=str, default=os.path.join(PROJECT_ROOT, "test_matrix_results.json"),
                        help="Đường dẫn kết quả JSON thô")
    parser.add_argument("--dest", type=str, default=None, help="Thư mục lưu file tải về")
    parser.add_argument("--no-crosscheck", action="store_true", help="Bỏ đối chiếu yt-dlp")
    args = parser.parse_args()

    if not os.path.exists(args.config):
        print(f"Không tìm thấy file cấu hình: {args.config}", file=sys.stderr)
        sys.exit(2)

    print("=" * 80)
    print("  Internet Downloader — Live Media Verification (app pipeline)")
    print("=" * 80)

    results = run_app_pipeline(
        args.config, args.json_output,
        platform=args.platform, timeout=args.timeout, dest=args.dest,
    )
    if results is None:
        print("Không chạy được pipeline của app.", file=sys.stderr)
        sys.exit(2)

    # Đối chiếu các ca fail bằng yt-dlp để biết lỗi là của app hay của nguồn.
    crosscheck = {}
    if not args.no_crosscheck:
        for r in results:
            if r["status"] != "PASS":
                print(f"==> Cross-check yt-dlp: {r['id']}")
                crosscheck[r["id"]] = ytdlp_crosscheck(r["requestedURL"])

    # Ca mà app KHÔNG tạo được file nào VÀ yt-dlp cũng không tải được → nguồn đã
    # chết/hết hạn, không phải lỗi app. Ghi SKIP thay vì FAIL để báo cáo không
    # bị méo. Nếu app ĐÃ tạo được file nhưng thiếu stream bắt buộc thì vẫn là
    # FAIL: đó là vấn đề thật của app (hoặc của bản thân nguồn) cần phải nêu ra.
    for r in results:
        if r["status"] == "FAIL" and crosscheck.get(r["id"]) is False and (r.get("sizeBytes") or 0) == 0:
            r["status"] = "SKIP"
            r["message"] = (f"{r['message']} — nguồn không còn truy cập được "
                            "(yt-dlp cũng không tải được)")

    # Ép luật audio từ config: ca expect_audio=true mà file thiếu luồng audio
    # phải FAIL, kể cả khi pipeline (hoặc JSON cũ) báo PASS.
    cases_by_id = load_case_expectations(args.config)
    forced_audio_failures = enforce_audio_expectations(results, cases_by_id)
    if forced_audio_failures:
        print(
            "==> Hạ PASS -> FAIL vì thiếu audio (expect_audio=true): "
            + ", ".join(forced_audio_failures)
        )

    required_failed = [r for r in results if r["status"] == "FAIL" and r.get("required", True)]
    required_skipped = [r for r in results if r["status"] == "SKIP" and r.get("required", True)]
    overall_passed = len(required_failed) == 0

    # Ghi lại trạng thái đã hạ cấp (FAIL → SKIP) vào file JSON để JSON và báo cáo
    # markdown không mâu thuẫn nhau.
    try:
        with open(args.json_output, "w", encoding="utf-8") as f:
            json.dump(results, f, ensure_ascii=False, indent=2)
    except OSError:
        pass

    report = build_report(results, crosscheck, overall_passed, time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    with open(args.output, "w", encoding="utf-8") as f:
        f.write(report)
    print(f"\nBáo cáo: {args.output}")

    print(report)
    sys.exit(0 if overall_passed else 1)


if __name__ == "__main__":
    main()
