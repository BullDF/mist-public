"""Run with: uv run --with brotli python3 mist/scripts/test_pak.py"""

import struct
import unittest

from pak import ALIAS, ENTRY, HEADER, Pak, compress, decompress
from rebrand_framework import (
    GAMES_PAGE_ID, NTP_SHELL_ID, blank_ntp_shell, locale_text, patch_locale, removed_menu_ids,
    strip_offline_games,
)


def fixture(encoding, entries, aliases=()):
    offset = HEADER.size + (len(entries) + 1) * ENTRY.size + len(aliases) * ALIAS.size
    table = []
    for resource_id, data in entries:
        table.append(ENTRY.pack(resource_id, offset))
        offset += len(data)
    return b"".join([
        HEADER.pack(5, encoding, len(entries), len(aliases)), *table, ENTRY.pack(0, offset),
        *(ALIAS.pack(*alias) for alias in aliases), *(data for _, data in entries),
    ])


class PakTests(unittest.TestCase):
    def test_ntp_shell_blanked_and_idempotent(self):
        shell = (
            b'<!doctype html><html dir="$i18n{textdirection}" lang="$i18n{language}">'
            b'<head><meta charset="utf-8"><title>$i18n{title}</title>'
            b'<style>body { background: $i18n{backgroundColor}; margin: 0; }</style></head>'
            b'<body><iframe id="backgroundImage"></iframe><ntp-app></ntp-app>'
            b'<script type="module" src="new_tab_page.js"></script>'
            b'<link rel="stylesheet" href="shared_vars.css"></body></html>'
        )
        for kind in ("raw", "gzip", "brotli"):
            with self.subTest(kind=kind):
                pak = Pak(fixture(1, [(NTP_SHELL_ID, compress(shell, kind))]))
                blank_ntp_shell(pak)
                parsed = Pak(pak.to_bytes())
                result = parsed.decoded(NTP_SHELL_ID)
                for kept in (
                    b'<!doctype html>', b'<meta charset="utf-8">',
                    b'dir="$i18n{textdirection}"', b'lang="$i18n{language}"',
                    b'<title>$i18n{title}</title>', b'background: $i18n{backgroundColor}',
                    b'html, body {', b'margin: 0;', b'height: 100%;',
                    b'<body></body>', b'data-mist-native-ntp="1"',
                ):
                    self.assertIn(kept, result)
                for removed in (b'<script', b'<ntp-app', b'<iframe', b'<link'):
                    self.assertNotIn(removed, result)
                self.assertEqual(decompress(parsed.resources[NTP_SHELL_ID])[1], kind)
                first = parsed.to_bytes()
                blank_ntp_shell(parsed)
                self.assertFalse(parsed.changed)
                self.assertEqual(parsed.to_bytes(), first)

    def test_ntp_shell_rejects_unrecognized_or_missing_resource(self):
        for shell in (b'<html></html>', b'<ntp-app></ntp-app>', b'new_tab_page.js'):
            with self.subTest(shell=shell):
                pak = Pak(fixture(1, [(NTP_SHELL_ID, shell)]))
                with self.assertRaisesRegex(ValueError, "NTP shell changed.*inspect the new framework"):
                    blank_ntp_shell(pak)
                self.assertFalse(pak.changed)
        with self.assertRaisesRegex(ValueError, "NTP shell changed"):
            blank_ntp_shell(Pak(fixture(1, [(2, b'other resource')])))

    def test_offline_games_stripped_and_idempotent(self):
        page = (
            b'<html><head><script>if(!holder||!holder.textContent){return}'
            b'window.PhiGames?.mount(host,{})</script></head>'
            b'<body><div id="phi-games-host"></div><div id="content"></div>'
            b'<script type="text/plain" id="phi-games-js">(function(){window.PhiGames={}})();\n'
            b'</script></body></html>'
        )
        for kind in ("raw", "gzip", "brotli"):
            with self.subTest(kind=kind):
                pak = Pak(fixture(1, [(GAMES_PAGE_ID, compress(page, kind))]))
                strip_offline_games(pak)
                parsed = Pak(pak.to_bytes())
                result = parsed.decoded(GAMES_PAGE_ID)
                for kept in (
                    b'<script type="text/plain" id="phi-games-js"></script>',
                    b'<div id="phi-games-host" data-mist-no-games="1" style="display: none"></div>',
                    b'<div id="content"></div>', b'window.PhiGames?.mount(host,{})',
                ):
                    self.assertIn(kept, result)
                self.assertNotIn(b'window.PhiGames={}', result)
                self.assertEqual(decompress(parsed.resources[GAMES_PAGE_ID])[1], kind)
                first = parsed.to_bytes()
                strip_offline_games(parsed)
                self.assertFalse(parsed.changed)
                self.assertEqual(parsed.to_bytes(), first)

    def test_offline_games_rejects_unrecognized_or_missing_resource(self):
        for page in (
            b'<html></html>',
            b'<div id="phi-games-host"></div><script type="text/plain" id="phi-games-js">x</script>',
            b'!holder.textContent){return}<script type="text/plain" id="phi-games-js">x</script>',
        ):
            with self.subTest(page=page):
                pak = Pak(fixture(1, [(GAMES_PAGE_ID, page)]))
                with self.assertRaisesRegex(ValueError, "Offline games page changed.*inspect the new framework"):
                    strip_offline_games(pak)
                self.assertFalse(pak.changed)
        with self.assertRaisesRegex(ValueError, "Offline games page changed"):
            strip_offline_games(Pak(fixture(1, [(2, b'other resource')])))

    def test_unchanged_roundtrip_preserves_bytes(self):
        raw = fixture(1, [(2, b"Phi"), (4, b"$1")], [(8, 0)])
        self.assertEqual(Pak(raw).to_bytes(), raw)

    def test_replacing_an_alias_does_not_change_its_original(self):
        pak = Pak(fixture(1, [(2, b"Phi"), (4, b"$1")], [(8, 0)]))
        pak.replace(8, b"Mist")
        reparsed = Pak(pak.to_bytes())
        self.assertEqual(reparsed.resources, {2: b"Phi", 4: b"$1", 8: b"Mist"})

    def test_replacing_original_does_not_change_alias(self):
        pak = Pak(fixture(1, [(2, b"Phi")], [(8, 0)]))
        pak.replace(2, b"Mist")
        self.assertEqual(Pak(pak.to_bytes()).resources, {2: b"Mist", 8: b"Phi"})

    def test_locale_aliases_cjk_placeholders_and_idempotence(self):
        for encoding, codec in [(1, "utf-8"), (2, "utf-16-le")]:
            with self.subTest(encoding=encoding):
                text = "Phi Browser $1 %s \u4f7f\u7528Phi Phinomenon phi-agent Phi2 aPhi PhiA"
                raw = fixture(encoding, [(2, text.encode(codec)), (4, b"\x00\x00\x01\x00")], [(8, 0)])
                pak = Pak(raw)
                self.assertEqual(patch_locale(pak), (3, 0))
                expected = "Mist $1 %s \u4f7f\u7528Mist Phinomenon phi-agent Mist2 aPhi PhiA"
                parsed = Pak(pak.to_bytes())
                self.assertEqual(parsed.decoded(2).decode(codec), expected)
                self.assertEqual(parsed.decoded(8).decode(codec), expected)
                self.assertEqual(parsed.resources[4], b"\x00\x00\x01\x00")
                first = parsed.to_bytes()
                self.assertEqual(patch_locale(parsed), (0, 0))
                self.assertEqual(parsed.to_bytes(), first)

    def test_removed_menu_titles_resolve_by_english_string(self):
        english = Pak(fixture(1, [(2, b"Open in Kiosk"), (4, b"Open in Kiosk Mode")]))
        self.assertEqual(removed_menu_ids(english), [2])
        french = Pak(fixture(2, [(2, "Ouvrir dans Kiosk".encode("utf-16-le"))]))
        self.assertEqual(locale_text(french, 2), "Ouvrir dans Kiosk")
        self.assertIsNone(locale_text(french, 4))
        for entries in ([(2, b"Open in Kiosk Mode")], [(2, b"Open in Kiosk"), (4, b"Open in Kiosk")]):
            with self.subTest(entries=entries), self.assertRaises(ValueError):
                removed_menu_ids(Pak(fixture(1, entries)))

    def test_compression_preserved_for_replacements(self):
        for kind in ("raw", "gzip", "brotli"):
            with self.subTest(kind=kind):
                pak = Pak(fixture(1, [(2, compress(b"Phi", kind))]))
                pak.replace(2, b"Mist")
                self.assertEqual(decompress(Pak(pak.to_bytes()).resources[2]), (b"Mist", kind))

    def test_rejects_invalid_headers_offsets_and_aliases(self):
        good = fixture(1, [(2, b"Phi")], [(8, 0)])
        mutations = [b"", good[:11], struct.pack("<I", 4) + good[4:]]
        bad_offset = bytearray(good)
        struct.pack_into("<I", bad_offset, 14, 0)
        mutations.append(bad_offset)
        bad_alias = bytearray(good)
        struct.pack_into("<H", bad_alias, HEADER.size + 2 * ENTRY.size + 2, 1)
        mutations.append(bad_alias)
        for data in mutations:
            with self.subTest(data=data):
                with self.assertRaises(ValueError):
                    Pak(data)

    def test_rejects_wrong_brotli_length(self):
        data = bytearray(compress(b"Phi", "brotli"))
        data[2] = 100
        with self.assertRaises(ValueError):
            decompress(data)


if __name__ == "__main__":
    unittest.main()
