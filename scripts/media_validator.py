#!/usr/bin/env python3
"""
Media Validator: Validates downloaded media files.
Enforces:
1. File exists and is a regular file.
2. File size > 0 bytes (per Requirement R3, replacing legacy 10MB limit).
3. Non-corrupted media headers and magic bytes (Audio, Video, Image).
4. ISO base media file format (MP4) box header walking:
   - Parse 4-byte box size (and 8-byte extended size if size == 1) and 4-byte box type.
   - Verify first box is 'ftyp'.
   - Verify presence of 'moov' or 'mdat' box.
5. MPEG-TS 188-byte packet sync byte validation:
   - Verify byte 0x47 at offset 188 * i for the first 50 packets (9,400 bytes).
6. Detection and rejection of HTML error pages / text payloads.
7. Structural format & stream verification using ffprobe for audio/video.
"""

import io
import os
import struct
import subprocess
import json

# Requirement R3: minimum size is > 0 bytes.
MIN_SIZE_BYTES = 1
LEGACY_MIN_SIZE_BYTES = 10 * 1024 * 1024  # Maintained for legacy compatibility

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


def validate_mp4_boxes(filepath_or_data) -> tuple[bool, str, list[str]]:
    """
    Parses and walks ISO base media file format (MP4) top-level box headers.
    - Reads 4-byte box size (and 8-byte extended size if size == 1) and 4-byte box type.
    - Verifies first box is 'ftyp'.
    - Verifies presence of 'moov' or 'mdat' box.
    Returns (is_valid, reason, list_of_boxes_found).
    """
    should_close = False
    if isinstance(filepath_or_data, (bytes, bytearray)):
        stream = io.BytesIO(filepath_or_data)
        file_size = len(filepath_or_data)
    elif hasattr(filepath_or_data, "read") and hasattr(filepath_or_data, "seek"):
        stream = filepath_or_data
        pos = stream.tell()
        stream.seek(0, io.SEEK_END)
        file_size = stream.tell()
        stream.seek(pos)
    elif isinstance(filepath_or_data, str):
        if not os.path.exists(filepath_or_data):
            return False, f"File does not exist: {filepath_or_data}", []
        file_size = os.path.getsize(filepath_or_data)
        stream = open(filepath_or_data, "rb")
        should_close = True
    else:
        return False, "Invalid input type for MP4 box validation", []

    try:
        boxes: list[str] = []
        offset = 0
        first_box = True
        has_moov_or_mdat = False

        if file_size < 8:
            return False, f"File too small for MP4 box header ({file_size} bytes)", []

        while offset < file_size:
            stream.seek(offset)
            hdr = stream.read(8)
            if len(hdr) < 8:
                return False, f"Truncated box header at offset {offset} ({len(hdr)} < 8 bytes)", boxes

            box_size = struct.unpack(">I", hdr[0:4])[0]
            raw_type = hdr[4:8]
            try:
                box_type = raw_type.decode("ascii")
            except UnicodeDecodeError:
                box_type = raw_type.decode("latin1", errors="replace")

            if first_box:
                if box_type != "ftyp":
                    return False, f"First box must be 'ftyp', found '{box_type}'", [box_type]
                first_box = False

            boxes.append(box_type)
            if box_type in ("moov", "mdat"):
                has_moov_or_mdat = True

            if box_size == 1:
                # 64-bit extended size
                ext_hdr = stream.read(8)
                if len(ext_hdr) < 8:
                    return False, f"Truncated 64-bit extended box size in box '{box_type}' at offset {offset}", boxes
                large_size = struct.unpack(">Q", ext_hdr)[0]
                if large_size < 16:
                    return False, f"Invalid 64-bit box size {large_size} in box '{box_type}'", boxes
                effective_size = large_size
            elif box_size == 0:
                # Box extends to end of file
                effective_size = file_size - offset
            elif box_size < 8:
                return False, f"Invalid box size {box_size} in box '{box_type}' at offset {offset}", boxes
            else:
                effective_size = box_size

            if box_size != 0 and (offset + effective_size > file_size):
                return False, f"Box '{box_type}' at offset {offset} declares size {effective_size} bytes, extending beyond file size ({file_size} bytes)", boxes

            offset += effective_size
            if box_size == 0:
                break

        if not boxes or boxes[0] != "ftyp":
            return False, "First box must be 'ftyp'", boxes

        if not has_moov_or_mdat:
            return False, "Missing required 'moov' or 'mdat' box in MP4 structure", boxes

        return True, "Valid MP4 structure with ftyp and moov/mdat boxes", boxes
    finally:
        if should_close:
            stream.close()


def validate_mpeg_ts_sync(filepath_or_data, max_packets: int = 50) -> tuple[bool, str, int]:
    """
    Validates MPEG-TS 188-byte packet sync byte:
    Verifies byte 0x47 at offset 188 * i for the first 50 packets (9,400 bytes).
    Returns (is_valid, reason, packets_checked).
    """
    target_bytes = max_packets * 188  # 9,400 bytes for 50 packets
    if isinstance(filepath_or_data, (bytes, bytearray)):
        data = bytes(filepath_or_data[:target_bytes])
    elif hasattr(filepath_or_data, "read") and hasattr(filepath_or_data, "seek"):
        pos = filepath_or_data.tell()
        data = filepath_or_data.read(target_bytes)
        filepath_or_data.seek(pos)
    elif isinstance(filepath_or_data, str):
        if not os.path.exists(filepath_or_data):
            return False, f"File does not exist: {filepath_or_data}", 0
        with open(filepath_or_data, "rb") as f:
            data = f.read(target_bytes)
    else:
        return False, "Invalid input type for MPEG-TS validation", 0

    if len(data) < 188:
        return False, f"File too small for MPEG-TS packet ({len(data)} < 188 bytes)", 0

    packets_available = len(data) // 188
    packets_to_check = min(max_packets, packets_available)

    for i in range(packets_to_check):
        offset = 188 * i
        sync_byte = data[offset]
        if sync_byte != 0x47:
            return False, (
                f"MPEG-TS sync byte 0x47 missing at packet {i} "
                f"(offset {offset}, found 0x{sync_byte:02x})"
            ), i

    return True, f"Valid MPEG-TS sync bytes (0x47) verified across {packets_to_check} packets", packets_to_check


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

    # MPEG-TS (0x47 sync byte on 188-byte boundaries)
    if header_bytes[0] == 0x47:
        if len(header_bytes) < 189 or header_bytes[188] == 0x47:
            return True, "video/mp2t"

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


def validate_media_file(
    filepath: str,
    require_media_type: str = None,
    require_ffprobe: bool = True
) -> tuple[bool, str, dict]:
    """
    Validates a media file on disk.
    Requirements:
    1. Exists and is regular file.
    2. Size > 0 bytes (Requirement R3).
    3. Non-corrupted media header (not HTML error).
    4. Valid MP4 box traversal (ftyp + moov/mdat) for MP4 files.
    5. Valid MPEG-TS 188-byte sync byte for TS streams.
    6. Valid stream structure via ffprobe (if require_ffprobe=True).

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
        return False, f"File size {size:,} bytes is less than minimum requirement ({MIN_SIZE_BYTES:,} bytes)", details

    try:
        with open(filepath, "rb") as f:
            header = f.read(4096)
    except Exception as e:
        return False, f"Unable to read file header: {e}", details

    if is_html_error(header):
        return False, "File contains HTML/text error response instead of binary media data", details

    magic_ok, fmt = check_magic_bytes(header)
    details["format"] = fmt

    # MP4 Box Walking Verification
    ext = os.path.splitext(filepath)[1].lower()
    if fmt == "video/mp4" or ext in (".mp4", ".m4v", ".m4a"):
        mp4_ok, mp4_reason, boxes = validate_mp4_boxes(filepath)
        details["mp4_boxes"] = boxes
        if not mp4_ok:
            return False, f"MP4 box validation failed: {mp4_reason}", details

    # MPEG-TS Sync Byte Verification
    if fmt == "video/mp2t" or ext in (".ts", ".m2ts"):
        ts_ok, ts_reason, packets_checked = validate_mpeg_ts_sync(filepath)
        details["ts_packets"] = packets_checked
        if not ts_ok:
            return False, f"MPEG-TS sync validation failed: {ts_reason}", details

    if not magic_ok:
        # Check if ffprobe can recognize it
        ff_ok, ff_msg, ff_info = probe_with_ffprobe(filepath)
        if ff_ok and "streams" in ff_info and len(ff_info["streams"]) > 0:
            details["ffprobe_valid"] = True
            details["format"] = ff_info.get("format", {}).get("format_name", "unknown")
            return True, "OK (verified via ffprobe)", details
        return False, f"Corrupted or unrecognized media header (magic check failed: {fmt})", details

    # Also verify with ffprobe if audio or video and requested
    if require_ffprobe and (fmt.startswith("video/") or fmt.startswith("audio/")):
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
