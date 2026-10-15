#!/usr/bin/env python3
"""
Unit tests for Media Validator.
Covers:
- Non-existent files
- 0-byte file rejection vs size > 0 acceptance (Requirement R3)
- HTML error page rejection
- Corrupted garbage rejection
- Magic byte detection (PNG, JPEG, WebM, MP3, etc.)
- ISO MP4 box walking (ftyp, moov, mdat, 64-bit extended size, size=0 to EOF, invalid first box, missing moov/mdat)
- MPEG-TS 188-byte packet sync byte validation (0x47 at 188 * i across 50 packets, corrupted sync byte, file too small)
- Full validate_media_file integration
"""

import os
import struct
import tempfile
import unittest
from media_validator import (
    validate_media_file,
    validate_mp4_boxes,
    validate_mpeg_ts_sync,
    check_magic_bytes,
    is_html_error,
    MIN_SIZE_BYTES,
)


class TestMediaValidator(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.temp_dir.cleanup()

    def create_file(self, filename: str, content: bytes, total_size: int = None) -> str:
        path = os.path.join(self.temp_dir.name, filename)
        with open(path, "wb") as f:
            f.write(content)
            if total_size is not None and total_size > len(content):
                f.seek(total_size - 1)
                f.write(b"\x00")
        return path

    def build_mp4_box(self, box_type: bytes, payload: bytes = b"", box_size: int = None) -> bytes:
        if box_size is None:
            box_size = 8 + len(payload)
        return struct.pack(">I", box_size) + box_type + payload

    def build_mp4_large_box(self, box_type: bytes, payload: bytes = b"", large_size: int = None) -> bytes:
        if large_size is None:
            large_size = 16 + len(payload)
        return struct.pack(">I", 1) + box_type + struct.pack(">Q", large_size) + payload

    def build_ts_packets(self, num_packets: int, corrupt_index: int = None) -> bytes:
        packets = bytearray()
        for i in range(num_packets):
            if corrupt_index is not None and i == corrupt_index:
                sync = b"\x00"
            else:
                sync = b"\x47"
            # 188-byte packet: sync byte + 187 bytes payload
            packet = sync + (b"\xff" * 187)
            packets.extend(packet)
        return bytes(packets)

    # -------------------------------------------------------------
    # 1. Basic File Checks & Size (Requirement R3)
    # -------------------------------------------------------------

    def test_nonexistent_file(self):
        path = os.path.join(self.temp_dir.name, "does_not_exist.mp4")
        ok, reason, details = validate_media_file(path)
        self.assertFalse(ok)
        self.assertIn("does not exist", reason.lower())

    def test_zero_byte_file_rejected(self):
        """0-byte files must be rejected per Requirement R3."""
        path = self.create_file("zero.mp4", b"", 0)
        ok, reason, details = validate_media_file(path)
        self.assertFalse(ok)
        self.assertIn("0 bytes", reason.lower())

    def test_size_greater_than_zero_passes_size_check(self):
        """Requirement R3: files with size > 0 (even < 10MB) pass size validation."""
        self.assertEqual(MIN_SIZE_BYTES, 1)
        # Small 500-byte PNG file (well under legacy 10MB)
        png_header = b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x10\x00\x00\x00\x10\x08\x06\x00\x00\x00"
        path = self.create_file("small_image.png", png_header, 500)
        ok, reason, details = validate_media_file(path)
        self.assertTrue(ok, f"Expected small PNG to pass, got: {reason}")
        self.assertEqual(details["size_bytes"], 500)
        self.assertEqual(details["format"], "image/png")

    # -------------------------------------------------------------
    # 2. HTML Error Rejection & Garbage Rejection
    # -------------------------------------------------------------

    def test_html_error_page_rejected(self):
        header = b"<!DOCTYPE html><html><head><title>404 Not Found</title></head><body><h1>Not Found</h1></body></html>"
        path = self.create_file("error.html", header, 1024)
        ok, reason, details = validate_media_file(path)
        self.assertFalse(ok)
        self.assertIn("html", reason.lower())

    def test_corrupted_garbage_rejected(self):
        header = b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10"
        path = self.create_file("garbage.bin", header, 4096)
        ok, reason, details = validate_media_file(path)
        self.assertFalse(ok)
        self.assertIn("magic check failed", reason.lower())

    # -------------------------------------------------------------
    # 3. Magic Byte Format Checks
    # -------------------------------------------------------------

    def test_valid_png_image(self):
        png_header = b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x01\x00\x00\x00\x01\x00\x08\x06\x00\x00\x00"
        path = self.create_file("valid.png", png_header, 4096)
        ok, reason, details = validate_media_file(path)
        self.assertTrue(ok, f"Expected valid PNG, got: {reason}")
        self.assertEqual(details["format"], "image/png")

    def test_valid_jpeg_image(self):
        jpeg_header = b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x01\x00H\x00H\x00\x00"
        path = self.create_file("valid.jpg", jpeg_header, 4096)
        ok, reason, details = validate_media_file(path)
        self.assertTrue(ok, f"Expected valid JPEG, got: {reason}")
        self.assertEqual(details["format"], "image/jpeg")

    def test_valid_mp3_with_id3(self):
        id3_header = b"ID3\x03\x00\x00\x00\x00\x00\x00\xff\xfb\x90\x64"
        magic_ok, fmt = check_magic_bytes(id3_header)
        self.assertTrue(magic_ok)
        self.assertEqual(fmt, "audio/mp3")

    def test_valid_webm_ebml(self):
        webm_header = b"\x1aE\xdf\xa3\x9f\x42\x86\x81\x01\x42\xf7\x81\x01\x42\xf2\x81\x04"
        magic_ok, fmt = check_magic_bytes(webm_header)
        self.assertTrue(magic_ok)
        self.assertEqual(fmt, "video/webm")

    # -------------------------------------------------------------
    # 4. MP4 Box Walking Unit Tests
    # -------------------------------------------------------------

    def test_mp4_box_walking_valid_ftyp_and_moov(self):
        """MP4 with ftyp first and moov present must pass."""
        ftyp = self.build_mp4_box(b"ftyp", b"isom\x00\x00\x02\x00isomiso2mp41")
        moov = self.build_mp4_box(b"moov", b"\x00" * 32)
        data = ftyp + moov

        ok, reason, boxes = validate_mp4_boxes(data)
        self.assertTrue(ok, f"Expected valid MP4, got: {reason}")
        self.assertEqual(boxes, ["ftyp", "moov"])

    def test_mp4_box_walking_valid_ftyp_moov_mdat(self):
        """Standard MP4 with ftyp, moov, and mdat boxes."""
        ftyp = self.build_mp4_box(b"ftyp", b"mp42\x00\x00\x00\x00mp42isom")
        moov = self.build_mp4_box(b"moov", b"\x00" * 16)
        mdat = self.build_mp4_box(b"mdat", b"\x00" * 64)
        data = ftyp + moov + mdat

        ok, reason, boxes = validate_mp4_boxes(data)
        self.assertTrue(ok, f"Expected valid MP4, got: {reason}")
        self.assertEqual(boxes, ["ftyp", "moov", "mdat"])

    def test_mp4_box_walking_valid_ftyp_and_mdat_only(self):
        """MP4 with ftyp and mdat (e.g. fragmented/fMP4 segment) must pass."""
        ftyp = self.build_mp4_box(b"ftyp", b"isom\x00\x00\x02\x00isomiso2mp41")
        mdat = self.build_mp4_box(b"mdat", b"\x11\x22\x33\x44")
        data = ftyp + mdat

        ok, reason, boxes = validate_mp4_boxes(data)
        self.assertTrue(ok, f"Expected valid MP4, got: {reason}")
        self.assertIn("mdat", boxes)

    def test_mp4_box_walking_64bit_extended_size(self):
        """MP4 box with size == 1 (64-bit uint64 large size) must parse correctly."""
        ftyp = self.build_mp4_box(b"ftyp", b"isom\x00\x00\x02\x00isomiso2mp41")
        # mdat with 64-bit size
        payload = b"large_payload_content_12345"
        mdat = self.build_mp4_large_box(b"mdat", payload, large_size=16 + len(payload))
        data = ftyp + mdat

        ok, reason, boxes = validate_mp4_boxes(data)
        self.assertTrue(ok, f"Expected valid 64-bit box parsing, got: {reason}")
        self.assertEqual(boxes, ["ftyp", "mdat"])

    def test_mp4_box_walking_size_zero_extends_to_eof(self):
        """MP4 box with size == 0 extends to EOF."""
        ftyp = self.build_mp4_box(b"ftyp", b"isom\x00\x00\x02\x00isomiso2mp41")
        mdat = self.build_mp4_box(b"mdat", b"payload_to_end_of_file", box_size=0)
        data = ftyp + mdat

        ok, reason, boxes = validate_mp4_boxes(data)
        self.assertTrue(ok, f"Expected valid size=0 box parsing, got: {reason}")
        self.assertEqual(boxes, ["ftyp", "mdat"])

    def test_mp4_box_walking_rejects_first_box_not_ftyp(self):
        """Reject MP4 if first box is NOT 'ftyp'."""
        moov = self.build_mp4_box(b"moov", b"\x00" * 16)
        mdat = self.build_mp4_box(b"mdat", b"\x00" * 32)
        data = moov + mdat

        ok, reason, boxes = validate_mp4_boxes(data)
        self.assertFalse(ok)
        self.assertIn("first box must be 'ftyp'", reason.lower())

    def test_mp4_box_walking_rejects_missing_moov_and_mdat(self):
        """Reject MP4 if first box is 'ftyp' but neither 'moov' nor 'mdat' is present."""
        ftyp = self.build_mp4_box(b"ftyp", b"isom\x00\x00\x02\x00isomiso2mp41")
        free = self.build_mp4_box(b"free", b"\x00" * 16)
        data = ftyp + free

        ok, reason, boxes = validate_mp4_boxes(data)
        self.assertFalse(ok)
        self.assertIn("missing required 'moov' or 'mdat'", reason.lower())

    def test_mp4_box_walking_rejects_truncated_header(self):
        """Reject MP4 data under 8 bytes."""
        data = b"\x00\x00\x00"
        ok, reason, boxes = validate_mp4_boxes(data)
        self.assertFalse(ok)
        self.assertIn("too small", reason.lower())

    def test_mp4_box_walking_rejects_invalid_box_size(self):
        """Reject box size < 8 (when not 0 or 1)."""
        ftyp = self.build_mp4_box(b"ftyp", b"isom\x00\x00\x02\x00isomiso2mp41")
        bad_box = struct.pack(">I", 4) + b"mdat"
        data = ftyp + bad_box

        ok, reason, boxes = validate_mp4_boxes(data)
        self.assertFalse(ok)
        self.assertIn("invalid box size", reason.lower())

    # -------------------------------------------------------------
    # 5. MPEG-TS Sync Byte (0x47) Unit Tests
    # -------------------------------------------------------------

    def test_mpeg_ts_valid_50_packets(self):
        """Verify 50 valid 188-byte packets (9,400 bytes) with 0x47 sync byte."""
        data = self.build_ts_packets(50)
        self.assertEqual(len(data), 9400)
        ok, reason, count = validate_mpeg_ts_sync(data, max_packets=50)
        self.assertTrue(ok, f"Expected valid MPEG-TS, got: {reason}")
        self.assertEqual(count, 50)

    def test_mpeg_ts_corrupted_sync_byte_rejected(self):
        """Verify corruption at packet 25 is caught."""
        data = self.build_ts_packets(50, corrupt_index=25)
        ok, reason, count = validate_mpeg_ts_sync(data, max_packets=50)
        self.assertFalse(ok)
        self.assertIn("packet 25", reason)
        self.assertEqual(count, 25)

    def test_mpeg_ts_file_too_small(self):
        """Reject TS data smaller than 188 bytes."""
        data = b"\x47" * 100
        ok, reason, count = validate_mpeg_ts_sync(data)
        self.assertFalse(ok)
        self.assertIn("too small", reason.lower())

    def test_mpeg_ts_fewer_than_50_packets_accepted(self):
        """Valid small TS stream with 10 packets checks all 10 packets."""
        data = self.build_ts_packets(10)
        ok, reason, count = validate_mpeg_ts_sync(data, max_packets=50)
        self.assertTrue(ok, f"Expected valid 10-packet TS, got: {reason}")
        self.assertEqual(count, 10)

    # -------------------------------------------------------------
    # 6. Integrated validate_media_file with MP4 & TS
    # -------------------------------------------------------------

    def test_validate_media_file_mp4_box_failure(self):
        """A file with extension .mp4 having corrupt MP4 boxes must fail validate_media_file."""
        moov = self.build_mp4_box(b"moov", b"\x00" * 32)
        path = self.create_file("bad_first_box.mp4", moov)
        ok, reason, details = validate_media_file(path, require_ffprobe=False)
        self.assertFalse(ok)
        self.assertIn("mp4 box validation failed", reason.lower())

    def test_validate_media_file_ts_success_and_failure(self):
        """A file with extension .ts is validated for MPEG-TS sync bytes."""
        good_ts = self.create_file("stream.ts", self.build_ts_packets(50))
        ok, reason, details = validate_media_file(good_ts, require_ffprobe=False)
        self.assertTrue(ok, f"Expected valid TS file, got: {reason}")
        self.assertEqual(details["ts_packets"], 50)

        bad_ts = self.create_file("corrupt_stream.ts", self.build_ts_packets(50, corrupt_index=12))
        ok, reason, details = validate_media_file(bad_ts, require_ffprobe=False)
        self.assertFalse(ok)
        self.assertIn("mpeg-ts sync validation failed", reason.lower())


if __name__ == "__main__":
    unittest.main()
