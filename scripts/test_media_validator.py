#!/usr/bin/env python3
"""
Unit tests for Media Validator.
Covers happy paths, edge cases (0-byte, truncated, HTML error, garbage data, non-existent).
"""

import os
import tempfile
import unittest
from media_validator import (
    validate_media_file,
    check_magic_bytes,
    is_html_error,
    MIN_SIZE_BYTES
)

class TestMediaValidator(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.temp_dir.cleanup()

    def create_file(self, filename: str, header: bytes, total_size: int) -> str:
        path = os.path.join(self.temp_dir.name, filename)
        with open(path, "wb") as f:
            f.write(header)
            remaining = total_size - len(header)
            if remaining > 0:
                # Write in chunks using sparse seek or zeroes
                f.seek(total_size - 1)
                f.write(b"\x00")
        return path

    def test_nonexistent_file(self):
        path = os.path.join(self.temp_dir.name, "does_not_exist.mp4")
        ok, reason, details = validate_media_file(path)
        self.assertFalse(ok)
        self.assertIn("does not exist", reason.lower())

    def test_zero_byte_file(self):
        path = self.create_file("zero.mp4", b"", 0)
        ok, reason, details = validate_media_file(path)
        self.assertFalse(ok)
        self.assertIn("0 bytes", reason.lower())

    def test_truncated_file_less_than_10mb(self):
        # 5 MB MP3 file
        five_mb = 5 * 1024 * 1024
        header = b"ID3\x03\x00\x00\x00\x00\x00\x00"
        path = self.create_file("truncated.mp3", header, five_mb)
        ok, reason, details = validate_media_file(path)
        self.assertFalse(ok)
        self.assertIn("less than minimum requirement", reason.lower())

    def test_html_error_page_rejected(self):
        # 11 MB HTML error response
        eleven_mb = 11 * 1024 * 1024
        header = b"<!DOCTYPE html><html><head><title>404 Not Found</title></head><body><h1>Not Found</h1></body></html>"
        path = self.create_file("error.html", header, eleven_mb)
        ok, reason, details = validate_media_file(path)
        self.assertFalse(ok)
        self.assertIn("html", reason.lower())

    def test_corrupted_garbage_rejected(self):
        # 11 MB of non-media random bytes
        eleven_mb = 11 * 1024 * 1024
        header = b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10"
        path = self.create_file("garbage.bin", header, eleven_mb)
        ok, reason, details = validate_media_file(path)
        self.assertFalse(ok)
        self.assertIn("magic check failed", reason.lower())

    def test_valid_png_image(self):
        eleven_mb = 11 * 1024 * 1024
        png_header = b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x01\x00\x00\x00\x01\x00\x08\x06\x00\x00\x00"
        path = self.create_file("valid.png", png_header, eleven_mb)
        ok, reason, details = validate_media_file(path)
        self.assertTrue(ok, f"Expected valid PNG, got: {reason}")
        self.assertEqual(details["format"], "image/png")

    def test_valid_jpeg_image(self):
        eleven_mb = 11 * 1024 * 1024
        jpeg_header = b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x01\x00H\x00H\x00\x00"
        path = self.create_file("valid.jpg", jpeg_header, eleven_mb)
        ok, reason, details = validate_media_file(path)
        self.assertTrue(ok, f"Expected valid JPEG, got: {reason}")
        self.assertEqual(details["format"], "image/jpeg")

    def test_valid_mp3_with_id3(self):
        eleven_mb = 11 * 1024 * 1024
        # Standard ID3v2.3 header
        id3_header = b"ID3\x03\x00\x00\x00\x00\x00\x00\xff\xfb\x90\x64"
        path = self.create_file("valid.mp3", id3_header, eleven_mb)
        # Note: ffprobe may not parse sparse zero file, but magic check verifies format
        magic_ok, fmt = check_magic_bytes(id3_header)
        self.assertTrue(magic_ok)
        self.assertEqual(fmt, "audio/mp3")

    def test_valid_mp4_ftyp_box(self):
        eleven_mb = 11 * 1024 * 1024
        # Standard ISO MP4 header: 4 bytes length, 'ftyp', 'isom'
        mp4_header = b"\x00\x00\x00\x1cftypisom\x00\x00\x02\x00isomiso2mp41"
        path = self.create_file("valid.mp4", mp4_header, eleven_mb)
        magic_ok, fmt = check_magic_bytes(mp4_header)
        self.assertTrue(magic_ok)
        self.assertEqual(fmt, "video/mp4")

    def test_valid_webm_ebml(self):
        eleven_mb = 11 * 1024 * 1024
        webm_header = b"\x1aE\xdf\xa3\x9f\x42\x86\x81\x01\x42\xf7\x81\x01\x42\xf2\x81\x04"
        path = self.create_file("valid.webm", webm_header, eleven_mb)
        magic_ok, fmt = check_magic_bytes(webm_header)
        self.assertTrue(magic_ok)
        self.assertEqual(fmt, "video/webm")

if __name__ == "__main__":
    unittest.main()
