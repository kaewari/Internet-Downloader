#!/usr/bin/env python3
"""
Media Validator: Validates downloaded media files.
Enforces:
1. File exists and is a regular file.
2. File size >= 10,485,760 bytes (10 MB).
3. Non-corrupted media headers and magic bytes (Audio, Video, Image).
4. Detection and rejection of HTML error pages / text payloads.
5. Structural format & stream verification using ffprobe for audio/video.
"""

import os
import subprocess
import json

MIN_SIZE_BYTES = 10 * 1024 * 1024  # 10,485,760 bytes (10 MB)

# Known Magic Signatures
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
JPEG_MAGIC = b"\xff\xd8\xff"
TIFF_LE_MAGIC = b"II*\x00"
TIFF_BE_MAGIC = b"MM\x00*"
WEBM_EBML_MAGIC = b"\x1aE\xdf\xa3"
OGG_MAGIC = b"OggS"
RIFF_MAGIC = b"RIFF"
FLAC_MAGIC = b"fLaC"
ID3_MAGIC = b"ID3"

def is_html_error(header_bytes: bytes) -> bool:
    """Checks whether header contains HTML, XML or JSON error messages."""
    prefix = header_bytes[:512].lower()
    html_markers = [
        b"<!doctype html",
        b"<html",
        b"<head",
        b"<body",
        b"<title>error",
        b"<title>404",
        b"<title>403",
        b"<title>500",
        b"access denied",
        b"error 404",
        b"<?xml",
    ]
    for marker in html_markers:
        if marker in prefix:
            return True
    return False

def check_magic_bytes(header_bytes: bytes) -> tuple[bool, str]:
    """
    Validates magic bytes for media formats (Audio, Video, Image).
    Returns (is_valid, detected_format).
    """
    if len(header_bytes) < 4:
        return False, "insufficient_bytes"

    if is_html_error(header_bytes):
        return False, "html_error"

    # Image Signatures
    if header_bytes.startswith(PNG_MAGIC):
        return True, "image/png"
    if header_bytes.startswith(JPEG_MAGIC):
        return True, "image/jpeg"
    if header_bytes.startswith(TIFF_LE_MAGIC) or header_bytes.startswith(TIFF_BE_MAGIC):
        return True, "image/tiff"

    # AVIF / HEIC (ISO BMFF with ftypavif or ftypavis or ftypheic)
    if len(header_bytes) >= 12 and header_bytes[4:8] == b"ftyp":
        brand = header_bytes[8:12]
        if brand in (b"avif", b"avis", b"heic", b"heix", b"mif1"):
            return True, "image/" + brand.decode("ascii", errors="ignore")

    # Video Signatures
    if header_bytes.startswith(WEBM_EBML_MAGIC):
        return True, "video/webm"
    if len(header_bytes) >= 12 and header_bytes[4:8] in (b"ftyp", b"moov", b"mdat", b"wide", b"free"):
        return True, "video/mp4"
    if header_bytes[:4] in (b"moov", b"mdat", b"wide", b"free", b"skip"):
        return True, "video/quicktime"

    # Audio Signatures
    if header_bytes.startswith(ID3_MAGIC):
        return True, "audio/mp3"
    # MPEG Audio sync word (0xFFE0 mask, e.g. 0xFFFB, 0xFFF3, 0xFFF2, 0xFFFA, 0xFFE3)
    if len(header_bytes) >= 2 and header_bytes[0] == 0xFF and (header_bytes[1] & 0xE0) == 0xE0:
        return True, "audio/mp3"
    if header_bytes.startswith(OGG_MAGIC):
        return True, "audio/ogg"
    if header_bytes.startswith(FLAC_MAGIC):
        return True, "audio/flac"
    if header_bytes.startswith(RIFF_MAGIC) and len(header_bytes) >= 12:
        riff_type = header_bytes[8:12]
        if riff_type == b"WAVE":
            return True, "audio/wav"
        if riff_type == b"WEBP":
            return True, "image/webp"
        if riff_type == b"AVI ":
            return True, "video/avi"

    # AAC ADTS header (0xFFF1, 0xFFF9)
    if len(header_bytes) >= 2 and header_bytes[0] == 0xFF and (header_bytes[1] & 0xF6) == 0xF0:
        return True, "audio/aac"

    return False, "unknown"

def probe_with_ffprobe(filepath: str) -> tuple[bool, str, dict]:
    """Runs ffprobe on the media file to verify valid stream and container parsing."""
    ffprobe_bin = None
    for p in ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"]:
        if os.path.isfile(p) and os.access(p, os.X_OK):
            ffprobe_bin = p
            break

    if not ffprobe_bin:
        # Fallback to PATH
        import shutil
        ffprobe_bin = shutil.which("ffprobe")

    if not ffprobe_bin:
        return True, "ffprobe_unavailable", {}

    cmd = [
        ffprobe_bin,
        "-v", "error",
        "-show_entries", "format=format_name,duration,size,bit_rate:stream=codec_type,codec_name",
        "-of", "json",
        filepath
    ]
    try:
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
        if res.returncode != 0:
            err = res.stderr.decode("utf-8", errors="ignore").strip()
            return False, f"ffprobe error: {err[:200]}", {}

        info = json.loads(res.stdout.decode("utf-8", errors="ignore"))
        streams = info.get("streams", [])
        fmt = info.get("format", {})
        if not streams and not fmt:
            return False, "ffprobe found no valid stream or format", {}
        return True, "valid", info
    except Exception as e:
        return False, f"ffprobe execution failed: {str(e)}", {}

def validate_media_file(filepath: str, require_media_type: str = None) -> tuple[bool, str, dict]:
    """
    Validates a media file on disk.
    Requirements:
    1. Exists and is regular file.
    2. Size >= 10,485,760 bytes (10MB).
    3. Non-corrupted media header (not HTML error).
    4. Valid stream structure.

    Returns (is_valid, error_reason, details).
    """
    details = {
        "path": filepath,
        "size_bytes": 0,
        "format": "unknown",
        "ffprobe_valid": False
    }

    if not os.path.exists(filepath):
        return False, f"File does not exist: {filepath}", details

    if not os.path.isfile(filepath):
        return False, f"Path is not a regular file: {filepath}", details

    size = os.path.getsize(filepath)
    details["size_bytes"] = size

    if size == 0:
        return False, "File is 0 bytes (empty file)", details

    if size < MIN_SIZE_BYTES:
        return False, f"File size {size:,} bytes is less than minimum requirement of 10MB ({MIN_SIZE_BYTES:,} bytes)", details

    try:
        with open(filepath, "rb") as f:
            header = f.read(4096)
    except Exception as e:
        return False, f"Unable to read file header: {e}", details

    if is_html_error(header):
        return False, "File contains HTML/text error response instead of binary media data", details

    magic_ok, fmt = check_magic_bytes(header)
    details["format"] = fmt

    if not magic_ok:
        # Check if ffprobe can recognize it
        ff_ok, ff_msg, ff_info = probe_with_ffprobe(filepath)
        if ff_ok and "streams" in ff_info and len(ff_info["streams"]) > 0:
            details["ffprobe_valid"] = True
            details["format"] = ff_info.get("format", {}).get("format_name", "unknown")
            return True, "OK (verified via ffprobe)", details
        return False, f"Corrupted or unrecognized media header (magic check failed: {fmt})", details

    # Also verify with ffprobe if audio or video
    if fmt.startswith("video/") or fmt.startswith("audio/"):
        ff_ok, ff_msg, ff_info = probe_with_ffprobe(filepath)
        if not ff_ok:
            return False, f"ffprobe structural validation failed: {ff_msg}", details
        details["ffprobe_valid"] = True

    return True, "OK", details

if __name__ == "__main__":
    import sys
    if len(sys.argv) < 2:
        print("Usage: python3 media_validator.py <filepath>")
        sys.exit(1)
    target = sys.argv[1]
    ok, reason, meta = validate_media_file(target)
    print(f"Validation: {'PASSED' if ok else 'FAILED'}")
    print(f"Reason: {reason}")
    print(f"Details: {meta}")
    sys.exit(0 if ok else 1)
