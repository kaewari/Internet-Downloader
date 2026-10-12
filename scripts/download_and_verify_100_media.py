#!/usr/bin/env python3
"""
Concurrent Downloader & Validator for 100 Media Files (>= 10MB each).
Downloads 100 media items concurrently across 100 unique hosts/domains.
Validates each file on disk:
- Size >= 10,485,760 bytes (10MB)
- Valid media structure & headers (Audio, Video, Image)
- Rejection of HTML error pages
- ffprobe stream inspection
Logs any failure to logs/download_100_media.log and automatically retries/fixes.
"""

import os
import sys
import time
import json
import ssl
import urllib.parse
import urllib.request
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed

# Add current scripts directory to import media_validator
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from media_validator import validate_media_file, MIN_SIZE_BYTES

DEST_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "Downloads", "Test100Media"))
LOG_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "logs"))
LOG_FILE = os.path.join(LOG_DIR, "download_100_media.log")
SOURCES_JSON = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "Sources", "Test100Sources", "sources.json"))

CONCURRENCY = 12
MAX_RETRIES = 5
CHUNK_SIZE = 128 * 1024  # 128 KB
SOCKET_TIMEOUT = 45

SSL_CTX = ssl.create_default_context()
SSL_CTX.check_hostname = False
SSL_CTX.verify_mode = ssl.CERT_NONE

BROWSER_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36",
    "Accept": "*/*",
    "Accept-Language": "en-US,en;q=0.9",
    "Connection": "keep-alive"
}

def log_event(message: str):
    """Appends timestamped event message to log file and stdout."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    formatted = f"[{timestamp}] {message}"
    os.makedirs(LOG_DIR, exist_ok=True)
    with open(LOG_FILE, "a", encoding="utf-8") as f:
        f.write(formatted + "\n")
    print(formatted)

def sanitize_filename(idx: int, host: str, url: str, mime: str, media_type: str) -> str:
    """Generates clean, safe filename with appropriate media extension."""
    clean_host = "".join(c if c.isalnum() or c in ("-", "_") else "_" for c in host)

    # Extract path extension
    parsed = urllib.parse.urlparse(url)
    ext = os.path.splitext(parsed.path)[1].lower().lstrip(".")

    # If no valid ext, determine from mime or media_type
    valid_exts = ("mp3", "mp4", "mov", "webm", "m4v", "wav", "ogg", "flac", "png", "jpg", "jpeg", "tif", "tiff", "avif", "webp")
    if not ext or ext not in valid_exts or len(ext) > 5:
        if "png" in mime: ext = "png"
        elif "jpeg" in mime or "jpg" in mime: ext = "jpg"
        elif "tiff" in mime or "tif" in mime: ext = "tif"
        elif "avif" in mime: ext = "avif"
        elif "webm" in mime: ext = "webm"
        elif "quicktime" in mime or "mov" in mime: ext = "mov"
        elif "mp4" in mime: ext = "mp4"
        elif "audio/mpeg" in mime or "audio/mp3" in mime: ext = "mp3"
        elif "m4a" in mime: ext = "m4a"
        elif media_type == "image": ext = "png"
        elif media_type == "video": ext = "mp4"
        else: ext = "mp3"

    return f"{idx:03d}_{clean_host}.{ext}"

def download_file(item: dict, idx: int) -> dict:
    """
    Downloads a single media file with range resume, chunk streaming, and retry policies.
    Returns status dictionary.
    """
    url = item["url"]
    host = item.get("host", "unknown")
    mime = item.get("mime", "")
    mtype = item.get("type", "unknown")
    target_filename = sanitize_filename(idx, host, url, mime, mtype)
    target_path = os.path.join(DEST_DIR, target_filename)

    # Check if already downloaded and valid
    if os.path.isfile(target_path):
        is_valid, reason, meta = validate_media_file(target_path)
        if is_valid:
            log_event(f"[SKIP/VERIFIED] #{idx:03d} [{host}] Already downloaded & valid: {meta['size_bytes']:,} bytes ({meta['size_bytes'] / (1024*1024):.2f} MB)")
            return {
                "idx": idx,
                "host": host,
                "path": target_path,
                "url": url,
                "status": "success",
                "bytes": meta["size_bytes"],
                "format": meta.get("format", "unknown")
            }

    attempt = 0
    while attempt < MAX_RETRIES:
        attempt += 1
        headers = dict(BROWSER_HEADERS)
        existing_size = os.path.getsize(target_path) if os.path.exists(target_path) else 0

        mode = "wb"
        if existing_size > 0:
            headers["Range"] = f"bytes={existing_size}-"
            mode = "ab"

        log_event(f"[START] #{idx:03d} [{host}] Attempt {attempt}/{MAX_RETRIES} (Offset: {existing_size:,} bytes)...")
        start_time = time.time()

        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, context=SSL_CTX, timeout=SOCKET_TIMEOUT) as resp:
                status = resp.status
                content_range = resp.headers.get("Content-Range")

                # If server doesn't support range resume (200 OK returned instead of 206), reset to wb
                if status == 200 and existing_size > 0:
                    log_event(f"[NOTICE] #{idx:03d} [{host}] Server does not support resume (status 200). Restarting from byte 0.")
                    mode = "wb"
                    existing_size = 0

                downloaded_chunk_bytes = 0
                with open(target_path, mode) as out_f:
                    while True:
                        chunk = resp.read(CHUNK_SIZE)
                        if not chunk:
                            break
                        out_f.write(chunk)
                        downloaded_chunk_bytes += len(chunk)

            total_file_size = os.path.getsize(target_path)
            duration = time.time() - start_time
            speed_mb = (downloaded_chunk_bytes / (1024 * 1024)) / max(0.1, duration)

            log_event(f"[FINISH] #{idx:03d} [{host}] Finished in {duration:.1f}s ({speed_mb:.2f} MB/s). File size: {total_file_size:,} bytes.")

            # Validate immediately
            is_valid, reason, meta = validate_media_file(target_path)
            if is_valid:
                log_event(f"[VALID] #{idx:03d} [{host}] PASS: {meta['size_bytes']:,} bytes ({meta.get('format', 'media')})")
                return {
                    "idx": idx,
                    "host": host,
                    "path": target_path,
                    "url": url,
                    "status": "success",
                    "bytes": total_file_size,
                    "format": meta.get("format", "unknown")
                }
            else:
                log_event(f"[INVALID] #{idx:03d} [{host}] Validation failed: {reason}")
                # If file is invalid (e.g. truncated or HTML error), remove and retry
                if os.path.exists(target_path):
                    os.remove(target_path)
                time.sleep(2 * attempt)

        except Exception as e:
            err_msg = str(e)
            log_event(f"[ERROR] #{idx:03d} [{host}] Attempt {attempt} failed: {err_msg}")
            # If 416 Range Not Satisfiable, file might already be complete or range was invalid
            if "416" in err_msg:
                if os.path.exists(target_path):
                    is_valid, reason, meta = validate_media_file(target_path)
                    if is_valid:
                        return {
                            "idx": idx,
                            "host": host,
                            "path": target_path,
                            "url": url,
                            "status": "success",
                            "bytes": meta["size_bytes"],
                            "format": meta.get("format", "unknown")
                        }
                    else:
                        os.remove(target_path)
            time.sleep(3 * attempt)

    log_event(f"[FATAL] #{idx:03d} [{host}] Exhausted all {MAX_RETRIES} attempts. URL: {url}")
    return {
        "idx": idx,
        "host": host,
        "path": target_path,
        "url": url,
        "status": "failed",
        "bytes": os.path.getsize(target_path) if os.path.exists(target_path) else 0,
        "error": "Exhausted retries"
    }

def main():
    print("=" * 70)
    print("  BACKGROUND CONCURRENT MEDIA DOWNLOADER & VALIDATOR (100 SOURCES)")
    print("  Target Directory: " + DEST_DIR)
    print("  Log File:         " + LOG_FILE)
    print("  Requirement:      100 files, min 10MB each, non-corrupted media")
    print("=" * 70)

    os.makedirs(DEST_DIR, exist_ok=True)
    os.makedirs(LOG_DIR, exist_ok=True)

    with open(SOURCES_JSON, "r", encoding="utf-8") as f:
        sources = json.load(f)

    if len(sources) != 100:
        log_event(f"[ERROR] Expected 100 sources in {SOURCES_JSON}, found {len(sources)}")
        sys.exit(1)

    log_event(f"Loaded 100 verified media sources from {SOURCES_JSON}.")
    log_event(f"Starting concurrent downloads with {CONCURRENCY} worker threads...")

    overall_start = time.time()
    results = []

    with ThreadPoolExecutor(max_workers=CONCURRENCY) as executor:
        futures = {executor.submit(download_file, item, i + 1): i for i, item in enumerate(sources)}
        for fut in as_completed(futures):
            res = fut.result()
            results.append(res)

    results.sort(key=lambda x: x["idx"])

    # Phase 2: Comprehensive Post-Download Disk Audit & Self-Healing Loop
    log_event("=" * 70)
    log_event("  PHASE 2: COMPREHENSIVE ON-DISK INTEGRITY & STRUCTURE VALIDATION")
    log_event("=" * 70)

    failed_items = []
    verified_files = []

    for item_res in results:
        idx = item_res["idx"]
        path = item_res["path"]
        host = item_res["host"]
        ok, reason, meta = validate_media_file(path)
        if ok:
            verified_files.append((idx, host, meta["size_bytes"], meta.get("format", "media"), path))
        else:
            log_event(f"[AUDIT FAIL] #{idx:03d} [{host}] Error: {reason}")
            failed_items.append((idx, sources[idx - 1]))

    # If any failed, retry them sequentially with maximum timeout & healing
    if failed_items:
        log_event(f"Healing {len(failed_items)} failed items with adaptive connection policy...")
        for idx, src in failed_items:
            log_event(f"[HEALING] Re-downloading item #{idx:03d} ({src['host']})...")
            fix_res = download_file(src, idx)
            ok, reason, meta = validate_media_file(fix_res["path"])
            if ok:
                verified_files.append((idx, src["host"], meta["size_bytes"], meta.get("format", "media"), fix_res["path"]))
            else:
                log_event(f"[HEAL FAILED] #{idx:03d} [{src['host']}]: {reason}")

    verified_files.sort(key=lambda x: x[0])

    total_time = time.time() - overall_start
    total_bytes = sum(x[2] for x in verified_files)

    print("\n" + "=" * 70)
    print("  FINAL 100 MEDIA COMPREHENSIVE VERIFICATION REPORT")
    print("=" * 70)
    print(f"Total Sources Processed:       100")
    print(f"Total Successfully Verified:   {len(verified_files)} / 100")
    print(f"Total Downloaded Size:         {total_bytes:,} bytes ({total_bytes / (1024**3):.2f} GiB)")
    if verified_files:
        min_file = min(verified_files, key=lambda x: x[2])
        max_file = max(verified_files, key=lambda x: x[2])
        print(f"Minimum File Size:             {min_file[2]:,} bytes ({min_file[2] / (1024*1024):.2f} MB) - #{min_file[0]:03d} [{min_file[1]}]")
        print(f"Maximum File Size:             {max_file[2]:,} bytes ({max_file[2] / (1024*1024):.2f} MB) - #{max_file[0]:03d} [{max_file[1]}]")
        all_ge_10mb = all(x[2] >= MIN_SIZE_BYTES for x in verified_files)
        print(f"All Files >= 10MB (10,485,760B): {'YES - 100% PASS' if all_ge_10mb else 'NO'}")
    print(f"Total Duration:                {total_time:.1f} seconds")
    print(f"Audit Log File:                {LOG_FILE}")
    print("=" * 70)

    if len(verified_files) == 100 and all(x[2] >= MIN_SIZE_BYTES for x in verified_files):
        log_event("[SUCCESS] All 100 media files verified successfully on disk!")
        sys.exit(0)
    else:
        log_event(f"[FAILURE] Only {len(verified_files)}/100 files verified.")
        sys.exit(1)

if __name__ == "__main__":
    main()
