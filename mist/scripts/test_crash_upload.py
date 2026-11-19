"""Run with: uv run --with brotli python3 mist/scripts/test_crash_upload.py"""

import unittest

from rebrand_framework import CRASH_UPLOAD_URL, blank_crash_upload_url


class CrashUploadTests(unittest.TestCase):
    def setUp(self):
        self.prefix = b"header\0"
        self.suffix = b"\0trailer"
        self.source = self.prefix + CRASH_UPLOAD_URL + self.suffix
        self.blanked = self.prefix + b"\0" * len(CRASH_UPLOAD_URL) + self.suffix

    def test_patch_preserves_length_and_zeroes_only_url(self):
        patched = blank_crash_upload_url(self.source, self.source)
        self.assertEqual(len(patched), len(self.source))
        self.assertEqual(patched, self.blanked)

    def test_already_patched_copy_returns_none(self):
        self.assertIsNone(blank_crash_upload_url(self.blanked, self.source))

    def test_source_without_url_raises(self):
        with self.assertRaisesRegex(ValueError, "Unrecognized Crashpad upload URL"):
            blank_crash_upload_url(self.source, self.blanked)

    def test_source_with_extra_sentry_domain_raises(self):
        with self.assertRaises(ValueError):
            blank_crash_upload_url(self.source, self.source + b"\0sentry.io\0")

    def test_source_with_duplicate_url_raises_even_when_copy_is_blanked(self):
        with self.assertRaises(ValueError):
            blank_crash_upload_url(self.blanked, self.source + self.source)

    def test_duplicate_url_in_copy_raises(self):
        with self.assertRaises(ValueError):
            blank_crash_upload_url(self.source + self.source, self.source)

    def test_copy_with_nonmatching_bytes_raises(self):
        with self.assertRaises(ValueError):
            blank_crash_upload_url(self.source.replace(b"https:", b"other:"), self.source)

    def test_copy_url_requires_both_nul_boundaries(self):
        for prefix, suffix in [(b"", self.suffix), (self.prefix, b""),
                               (b"header", self.suffix), (self.prefix, b"trailer")]:
            with self.subTest(prefix=prefix, suffix=suffix):
                with self.assertRaises(ValueError):
                    blank_crash_upload_url(prefix + CRASH_UPLOAD_URL + suffix, self.source)

    def test_truncated_or_shifted_blanked_copy_raises(self):
        for copy in [self.blanked[:len(self.prefix) + len(CRASH_UPLOAD_URL) - 1],
                     b"xx" + self.blanked]:
            with self.subTest(copy=copy):
                with self.assertRaises(ValueError):
                    blank_crash_upload_url(copy, self.source)


if __name__ == "__main__":
    unittest.main()
