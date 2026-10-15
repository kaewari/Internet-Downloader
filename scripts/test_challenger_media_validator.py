#!/usr/bin/env python3
"""
Adversarial and Empirical Stress Test Suite for scripts/media_validator.py
Executed by Challenger 1 (teamwork_preview_challenger).

Tests edge-case payloads, malformed structures, crash resilience,
and boundary conditions for media validation.
"""

import os
import struct
import tempfile
import unittest
import sys

# Ensure scripts directory is on sys.path
SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, SCRIPTS_DIR)

from media_validator import (
    validate_media_file,
    validate_mp4_boxes,
    validate_mpeg_ts_sync,
    check_magic_bytes,
    is_html_error,
    MIN_SIZE_BYTES,
)


class TestChallengerMediaValidator(unittest.TestCase):
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

    def build_ts_packets(self, num_packets: int, corrupt_index: int = None, corrupt_byte: int = 0x00) -> bytes:
        packets = bytearray()
        for i in range(num_packets):
            if corrupt_index is not None and i == corrupt_index:
                sync = bytes([corrupt_byte])
            else:
                sync = b"\x47"
            packet = sync + (b"\xff" * 187)
            packets.extend(packet)
        return bytes(packets)

    # =========================================================================
    # Group 1: Empty Files & Zero-Byte Payloads
    # =========================================================================

    def test_zero_byte_file_rejected_by_validate_media_file(self):
        """0-byte file must be rejected with clear reason."""
        path = self.create_file("empty.mp4", b"")
        ok, reason, details = validate_media_file(path)
        self.assertFalse(ok, "0-byte file must NOT pass validation")
        self.assertIn("0 bytes", reason.lower())
        self.assertEqual(details["size_bytes"], 0)

    def test_zero_byte_bytesio_mp4_boxes(self):
        """0-byte data passed to validate_mp4_boxes must return False without exception."""
        ok, reason, boxes = validate_mp4_boxes(b"")
        self.assertFalse(ok)
        self.assertIn("too small", reason.lower())
        self.assertEqual(boxes, [])

    def test_zero_byte_bytesio_ts_sync(self):
        """0-byte data passed to validate_mpeg_ts_sync must return False without exception."""
        ok, reason, count = validate_mpeg_ts_sync(b"")
        self.assertFalse(ok)
        self.assertIn("too small", reason.lower())
        self.assertEqual(count, 0)

    def test_zero_byte_magic_check(self):
        """0-byte header passed to check_magic_bytes returns False."""
        ok, fmt = check_magic_bytes(b"")
        self.assertFalse(ok)
        self.assertEqual(fmt, "insufficient_bytes")

    # =========================================================================
    # Group 2: Truncated MP4 Files & Box Header Violations
    # =========================================================================

    def test_mp4_under_8_bytes_rejected(self):
        """MP4 data under 8 bytes (cannot form single box header) must be rejected."""
        for size in [1, 3, 5, 7]:
            data = b"\x00" * size
            ok, reason, boxes = validate_mp4_boxes(data)
            self.assertFalse(ok, f"Data of size {size} should be rejected")
            self.assertIn("too small", reason.lower())

    def test_mp4_invalid_box_size_small(self):
        """Box sizes 2, 3, 4, 5, 6, 7 are structurally invalid in ISO BMFF."""
        ftyp = self.build_mp4_box(b"ftyp", b"isom" + struct.pack(">I", 512))
        for bad_size in [2, 3, 4, 5, 6, 7]:
            bad_box = struct.pack(">I", bad_size) + b"mdat"
            payload = ftyp + bad_box
            ok, reason, boxes = validate_mp4_boxes(payload)
            self.assertFalse(ok, f"Box size {bad_size} must be rejected")
            self.assertIn("invalid box size", reason.lower())

    def test_mp4_64bit_size_less_than_16(self):
        """When box_size == 1, 64-bit large_size < 16 is structurally invalid."""
        ftyp = self.build_mp4_box(b"ftyp", b"isom" + struct.pack(">I", 512))
        for bad_large in [0, 8, 12, 15]:
            bad_box = struct.pack(">I", 1) + b"mdat" + struct.pack(">Q", bad_large)
            payload = ftyp + bad_box
            ok, reason, boxes = validate_mp4_boxes(payload)
            self.assertFalse(ok, f"64-bit large_size {bad_large} must be rejected")
            self.assertIn("invalid 64-bit box size", reason.lower())

    def test_mp4_64bit_header_truncated_before_large_size(self):
        """When box_size == 1, file ending before the 8-byte uint64 large_size is truncated."""
        ftyp = self.build_mp4_box(b"ftyp", b"isom" + struct.pack(">I", 512))
        # Only provide 4 bytes of extended size instead of 8
        bad_box = struct.pack(">I", 1) + b"mdat" + b"\x00\x00\x00\x01"
        payload = ftyp + bad_box
        ok, reason, boxes = validate_mp4_boxes(payload)
        self.assertFalse(ok)
        self.assertIn("truncated 64-bit extended box size", reason.lower())

    def test_mp4_box_extends_past_eof_32bit_adversarial(self):
        """
        Adversarial Test: An MP4 file has a valid 'ftyp' box and a 'moov' box header
        whose declared box_size (e.g. 100,000 bytes) extends FAR beyond the file's
        actual length (e.g. only 24 bytes).
        ISO BMFF requires each box payload to be contained within the file.
        """
        ftyp = self.build_mp4_box(b"ftyp", b"isom" + struct.pack(">I", 512))  # 16 bytes
        truncated_moov_header = struct.pack(">I", 100000) + b"moov"           # 8 bytes
        payload = ftyp + truncated_moov_header                                # 24 bytes total

        ok, reason, boxes = validate_mp4_boxes(payload)
        # Note: If validate_mp4_boxes currently does not check (offset + effective_size > file_size),
        # this test will fail, identifying the vulnerability empirically.
        self.assertFalse(
            ok,
            f"VULNERABILITY DETECTED: Truncated MP4 (moov declares 100,000 bytes in 24-byte file) "
            f"was incorrectly accepted! Reason given: {reason}"
        )

    def test_mp4_box_extends_past_eof_64bit_adversarial(self):
        """
        Adversarial Test: An MP4 file with 64-bit large_size extending beyond file size
        (e.g. large_size = 2**63 in a 40-byte file).
        """
        ftyp = self.build_mp4_box(b"ftyp", b"isom" + struct.pack(">I", 512))  # 16 bytes
        huge_large_size = 2**63
        truncated_mdat_header = (
            struct.pack(">I", 1) + b"mdat" + struct.pack(">Q", huge_large_size)
        )                                                                     # 16 bytes
        payload = ftyp + truncated_mdat_header                                # 32 bytes total

        ok, reason, boxes = validate_mp4_boxes(payload)
        self.assertFalse(
            ok,
            f"VULNERABILITY DETECTED: Truncated MP4 with 64-bit large_size={huge_large_size} "
            f"in 32-byte file was incorrectly accepted! Reason given: {reason}"
        )

    def test_mp4_truncated_box_header_at_eof(self):
        """
        Adversarial Test: An MP4 file has valid ftyp and moov, but is followed by a
        truncated box header (< 8 bytes, e.g. 4 bytes).
        """
        ftyp = self.build_mp4_box(b"ftyp", b"isom" + struct.pack(">I", 512))  # 16 bytes
        moov = self.build_mp4_box(b"moov", b"\x00" * 16)                     # 24 bytes
        partial_box_header = b"\x00\x00\x00\x20"                             # 4 bytes only
        payload = ftyp + moov + partial_box_header

        ok, reason, boxes = validate_mp4_boxes(payload)
        self.assertFalse(
            ok,
            f"VULNERABILITY DETECTED: MP4 with truncated trailing box header (4 bytes) "
            f"was accepted! Reason given: {reason}"
        )

    # =========================================================================
    # Group 3: MP4 Box Ordering and Content Requirements
    # =========================================================================

    def test_mp4_missing_ftyp_as_first_box(self):
        """MP4 starting with 'moov', 'mdat', 'free', or 'skip' must be rejected."""
        for first_type in [b"moov", b"mdat", b"free", b"skip", b"wide"]:
            box1 = self.build_mp4_box(first_type, b"\x00" * 16)
            box2 = self.build_mp4_box(b"mdat", b"\x00" * 16)
            ok, reason, boxes = validate_mp4_boxes(box1 + box2)
            self.assertFalse(ok, f"MP4 starting with '{first_type.decode()}' must be rejected")
            self.assertIn("first box must be 'ftyp'", reason.lower())

    def test_mp4_ftyp_only_missing_moov_and_mdat(self):
        """MP4 containing only 'ftyp' box must be rejected (missing moov and mdat)."""
        ftyp = self.build_mp4_box(b"ftyp", b"isom" + struct.pack(">I", 512))
        ok, reason, boxes = validate_mp4_boxes(ftyp)
        self.assertFalse(ok)
        self.assertIn("missing required 'moov' or 'mdat'", reason.lower())

    def test_mp4_ftyp_and_free_only(self):
        """MP4 with 'ftyp' and 'free'/'skip' boxes but missing both 'moov' and 'mdat' must be rejected."""
        ftyp = self.build_mp4_box(b"ftyp", b"isom" + struct.pack(">I", 512))
        free = self.build_mp4_box(b"free", b"\x00" * 32)
        ok, reason, boxes = validate_mp4_boxes(ftyp + free)
        self.assertFalse(ok)
        self.assertIn("missing required 'moov' or 'mdat'", reason.lower())

    def test_mp4_valid_ftyp_and_moov(self):
        """Valid MP4 with ftyp and moov must pass validate_mp4_boxes."""
        ftyp = self.build_mp4_box(b"ftyp", b"isom" + struct.pack(">I", 512))
        moov = self.build_mp4_box(b"moov", b"\x00" * 32)
        ok, reason, boxes = validate_mp4_boxes(ftyp + moov)
        self.assertTrue(ok, f"Valid ftyp + moov failed: {reason}")
        self.assertEqual(boxes, ["ftyp", "moov"])

    def test_mp4_valid_ftyp_and_mdat(self):
        """Valid fragmented MP4 (fMP4) segment with ftyp and mdat must pass."""
        ftyp = self.build_mp4_box(b"ftyp", b"isom" + struct.pack(">I", 512))
        mdat = self.build_mp4_box(b"mdat", b"\x00" * 64)
        ok, reason, boxes = validate_mp4_boxes(ftyp + mdat)
        self.assertTrue(ok, f"Valid ftyp + mdat failed: {reason}")
        self.assertEqual(boxes, ["ftyp", "mdat"])

    def test_mp4_valid_ftyp_moov_mdat(self):
        """Standard full MP4 with ftyp, moov, and mdat boxes must pass."""
        ftyp = self.build_mp4_box(b"ftyp", b"mp42" + struct.pack(">I", 0) + b"mp42isom")
        moov = self.build_mp4_box(b"moov", b"\x00" * 32)
        mdat = self.build_mp4_box(b"mdat", b"\x00" * 128)
        ok, reason, boxes = validate_mp4_boxes(ftyp + moov + mdat)
        self.assertTrue(ok, f"Valid standard MP4 failed: {reason}")
        self.assertEqual(boxes, ["ftyp", "moov", "mdat"])

    def test_mp4_size_zero_extends_to_eof(self):
        """When last box has box_size == 0, it extends to EOF and is valid."""
        ftyp = self.build_mp4_box(b"ftyp", b"isom" + struct.pack(">I", 512))
        mdat = self.build_mp4_box(b"mdat", b"sample_video_payload_12345", box_size=0)
        ok, reason, boxes = validate_mp4_boxes(ftyp + mdat)
        self.assertTrue(ok, f"Box size 0 at EOF failed: {reason}")
        self.assertEqual(boxes, ["ftyp", "mdat"])

    # =========================================================================
    # Group 4: MPEG-TS Truncation, Sync Byte, and Boundary Checks
    # =========================================================================

    def test_mpeg_ts_truncated_less_than_188_bytes(self):
        """MPEG-TS under 188 bytes must be rejected by validate_mpeg_ts_sync."""
        for size in [1, 50, 100, 187]:
            payload = b"\x47" + (b"\xff" * (size - 1)) if size > 0 else b""
            ok, reason, count = validate_mpeg_ts_sync(payload)
            self.assertFalse(ok, f"MPEG-TS of size {size} must be rejected")
            self.assertIn("too small", reason.lower())
            self.assertEqual(count, 0)

    def test_mpeg_ts_exactly_188_bytes_crash_check(self):
        """
        Adversarial Test: Exactly 188 bytes (single valid TS packet).
        Verifies check_magic_bytes and validate_media_file do NOT crash with
        IndexError: index out of range.
        """
        single_packet = b"\x47" + (b"\xff" * 187)
        self.assertEqual(len(single_packet), 188)

        # 1. Test check_magic_bytes directly
        try:
            magic_ok, fmt = check_magic_bytes(single_packet)
        except IndexError as e:
            self.fail(f"CRASH: check_magic_bytes crashed with IndexError on 188-byte TS: {e}")

        # 2. Test validate_media_file with 188-byte file
        path = self.create_file("single_packet.ts", single_packet)
        try:
            ok, reason, details = validate_media_file(path, require_ffprobe=False)
        except IndexError as e:
            self.fail(f"CRASH: validate_media_file crashed with IndexError on 188-byte TS: {e}")

        self.assertTrue(ok, f"Valid 188-byte MPEG-TS packet should pass, got: {reason}")
        self.assertEqual(details["ts_packets"], 1)

    def test_mpeg_ts_missing_sync_byte_at_offset_0(self):
        """Packet 0 sync byte != 0x47 must be rejected."""
        payload = self.build_ts_packets(50, corrupt_index=0, corrupt_byte=0x00)
        ok, reason, count = validate_mpeg_ts_sync(payload)
        self.assertFalse(ok)
        self.assertIn("packet 0", reason)
        self.assertEqual(count, 0)

    def test_mpeg_ts_missing_sync_byte_at_offset_1(self):
        """Packet 1 sync byte != 0x47 must be rejected."""
        payload = self.build_ts_packets(50, corrupt_index=1, corrupt_byte=0x46)
        ok, reason, count = validate_mpeg_ts_sync(payload)
        self.assertFalse(ok)
        self.assertIn("packet 1", reason)
        self.assertEqual(count, 1)

    def test_mpeg_ts_missing_sync_byte_at_offset_49(self):
        """Packet 49 sync byte != 0x47 must be rejected."""
        payload = self.build_ts_packets(50, corrupt_index=49, corrupt_byte=0xAA)
        ok, reason, count = validate_mpeg_ts_sync(payload)
        self.assertFalse(ok)
        self.assertIn("packet 49", reason)
        self.assertEqual(count, 49)

    def test_mpeg_ts_valid_50_packets(self):
        """Valid MPEG-TS with 0x47 sync byte across 50 packets (9,400 bytes) must pass."""
        payload = self.build_ts_packets(50)
        self.assertEqual(len(payload), 9400)
        ok, reason, count = validate_mpeg_ts_sync(payload, max_packets=50)
        self.assertTrue(ok, f"Valid 50-packet MPEG-TS failed: {reason}")
        self.assertEqual(count, 50)

    def test_mpeg_ts_valid_more_than_50_packets_caps_at_50(self):
        """Valid MPEG-TS with 100 packets checks first 50 packets."""
        payload = self.build_ts_packets(100)
        ok, reason, count = validate_mpeg_ts_sync(payload, max_packets=50)
        self.assertTrue(ok)
        self.assertEqual(count, 50)

    # =========================================================================
    # Group 5: HTML / Text Error Pages Disguised as MP4/TS
    # =========================================================================

    def test_html_doctype_error_disguised_as_mp4(self):
        """HTML 404 page with .mp4 extension must be rejected."""
        html_payload = (
            b"<!DOCTYPE html>\n<html>\n<head><title>404 Not Found</title></head>\n"
            b"<body><h1>Not Found</h1><p>The requested media was not found.</p></body>\n</html>"
        )
        path = self.create_file("video.mp4", html_payload)
        ok, reason, details = validate_media_file(path, require_ffprobe=False)
        self.assertFalse(ok, "HTML error page with .mp4 extension must be rejected")
        self.assertIn("html/text error", reason.lower())

    def test_html_error_disguised_as_ts(self):
        """HTML 403 Forbidden page with .ts extension must be rejected."""
        html_payload = (
            b"<html><head><title>403 Forbidden</title></head>"
            b"<body><h1>Access Denied</h1></body></html>"
        )
        path = self.create_file("segment.ts", html_payload)
        ok, reason, details = validate_media_file(path, require_ffprobe=False)
        self.assertFalse(ok, "HTML error page with .ts extension must be rejected")
        self.assertIn("html/text error", reason.lower())

    def test_plain_text_404_disguised_as_mp4(self):
        """Plain text '404 Not Found' response disguised as .mp4 must be rejected."""
        text_payload = b"404 Not Found\nThe requested video URL has expired."
        path = self.create_file("error.mp4", text_payload)
        ok, reason, details = validate_media_file(path, require_ffprobe=False)
        self.assertFalse(ok, "Plain text error response disguised as .mp4 must be rejected")

    def test_gateway_timeout_text_starting_with_G_disguised_as_ts(self):
        """
        Adversarial Test: Plain text error 'Gateway Timeout 504' begins with 'G' (ASCII 0x47).
        Saved as .ts, it must still be rejected (fails sync byte at offset 188).
        """
        text_payload = (
            b"Gateway Timeout (504): The upstream server failed to respond in time.\n"
            b"Please retry the request later or contact server administrator.\n"
        ) * 10  # > 188 bytes
        self.assertEqual(text_payload[0], 0x47)  # 'G' == 0x47

        path = self.create_file("stream.ts", text_payload)
        ok, reason, details = validate_media_file(path, require_ffprobe=False)
        self.assertFalse(ok, "Text error starting with 'G' (0x47) must be rejected")

    def test_xml_access_denied_disguised_as_mp4(self):
        """XML S3/GCS AccessDenied error disguised as .mp4 must be rejected."""
        xml_payload = (
            b'<?xml version="1.0" encoding="UTF-8"?>\n'
            b'<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>'
        )
        path = self.create_file("stream.mp4", xml_payload)
        ok, reason, details = validate_media_file(path, require_ffprobe=False)
        self.assertFalse(ok, "XML AccessDenied payload disguised as .mp4 must be rejected")

    # =========================================================================
    # Group 6: Robustness & Non-Crash Guarantees
    # =========================================================================

    def test_nonexistent_file_handling(self):
        """Nonexistent file path must return False gracefully without raising exceptions."""
        bad_path = os.path.join(self.temp_dir.name, "does_not_exist_98765.mp4")
        ok, reason, details = validate_media_file(bad_path)
        self.assertFalse(ok)
        self.assertIn("does not exist", reason.lower())

    def test_directory_path_handling(self):
        """A directory path passed as file must return False gracefully."""
        ok, reason, details = validate_media_file(self.temp_dir.name)
        self.assertFalse(ok)
        self.assertIn("regular file", reason.lower())

    def test_invalid_data_types_mp4(self):
        """Invalid data types passed to validate_mp4_boxes must return False gracefully."""
        for invalid in [None, 12345, 3.14, [], {}]:
            ok, reason, boxes = validate_mp4_boxes(invalid)
            self.assertFalse(ok)
            self.assertIn("invalid input type", reason.lower())

    def test_invalid_data_types_ts(self):
        """Invalid data types passed to validate_mpeg_ts_sync must return False gracefully."""
        for invalid in [None, 12345, 3.14, [], {}]:
            ok, reason, count = validate_mpeg_ts_sync(invalid)
            self.assertFalse(ok)
            self.assertIn("invalid input type", reason.lower())

    def test_box_type_with_non_ascii_bytes(self):
        """MP4 box header with non-ASCII / binary box_type decodes without UnicodeDecodeError."""
        ftyp = self.build_mp4_box(b"ftyp", b"isom" + struct.pack(">I", 512))
        weird_box = struct.pack(">I", 16) + b"\xff\xfe\xfd\xfc" + (b"\x00" * 8)
        payload = ftyp + weird_box
        # Should parse without throwing UnicodeDecodeError
        ok, reason, boxes = validate_mp4_boxes(payload)
        self.assertEqual(boxes[0], "ftyp")
        self.assertEqual(len(boxes), 2)


if __name__ == "__main__":
    unittest.main()
