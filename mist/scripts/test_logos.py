"""Run with: python3 mist/scripts/test_logos.py"""

import hashlib
import unittest
import xml.etree.ElementTree as ET

from pak import BROTLI, Pak, compress
from rebrand_framework import (
    NTP_MARKER, PHI_PRODUCT_SHA256, PNG_MARKER, SVG_TARGETS, logo_svg,
    patch_product_icons, product_icon, replace_logo, replace_product_icon,
)
from test_pak import fixture


ORIGINAL_ICON = b'''<g id="phi-product" viewBox="0 0 960 960">
        <path d="M696.692 392.315C696.692 298.625 620.397 222.389 526.566 222.389C414.639 222.389 323.463 313.426 323.463 425.336C323.463 558.679 432.036 667.169 565.482 667.169C724.219 667.169 853.333 538.224 853.333 379.539C853.333 191.392 700.115 38.2222 511.685 38.2222C288.32 38.2222 106.667 219.736 106.667 442.929C106.667 701.308 312.424 912.562 568.905 921.778V701.727H565.552C413.033 701.727 288.949 577.738 288.949 425.336C288.949 294.437 395.566 187.832 526.636 187.832C639.541 187.832 731.346 279.566 731.346 392.315C731.346 488.727 653.584 566.987 557.447 568.453C507.055 568.453 463.896 527.946 463.896 476.579C463.896 426.174 505.187 384.426 556.12 384.426C607.053 384.426 648.344 425.685 648.344 476.579C648.344 485.794 645.619 494.172 643.104 502.55C675.522 476.509 696.762 437.065 696.762 392.315H696.692Z">
        </path>
      </g>'''


class LogoTests(unittest.TestCase):
    def test_png_and_svg_original_marker_and_unknown_rules(self):
        for marker, pack in [(PNG_MARKER, "chrome_100_percent.pak"),
                             (NTP_MARKER.encode(), "resources.pak")]:
            with self.subTest(pack=pack):
                original = b"original logo"
                original_hash = hashlib.sha256(original).hexdigest()
                replacement = b"current logo " + marker
                args = (replacement, original_hash, marker, 123, pack)
                self.assertEqual(replace_logo(original, *args), replacement)
                self.assertEqual(replace_logo(b"old logo " + marker, *args), replacement)
                self.assertEqual(replace_logo(replacement, *args), replacement)
                with self.assertRaisesRegex(ValueError, f"Unrecognized Phi logo resource 123 in {pack}"):
                    replace_logo(b"unknown logo", *args)

    def test_svg_canvas_mask_and_fill(self):
        namespace = "{http://www.w3.org/2000/svg}"
        for resource_id, (_, width, height, fill, side, y) in SVG_TARGETS.items():
            with self.subTest(resource_id=resource_id):
                svg = ET.fromstring(logo_svg(b"mask", width, height, fill, side, y))
                self.assertEqual(svg.attrib, {
                    "data-mist-logo": "1", "width": str(width), "height": str(height),
                    "viewBox": f"0 0 {width} {height}",
                })
                mask = svg.find(namespace + "mask")
                self.assertEqual(mask.get("style"), "mask-type:alpha")
                image = mask.find(namespace + "image")
                self.assertEqual((image.get("width"), image.get("height"), image.get("y")),
                                 (str(side), str(side), str(y)))
                self.assertEqual(image.get("href"), "data:image/png;base64,bWFzaw==")
                self.assertEqual(svg.find(namespace + "rect").get("fill"), fill)

    def test_original_icon_replaced_and_surrounding_bytes_preserved(self):
        self.assertEqual(hashlib.sha256(ORIGINAL_ICON).hexdigest(), PHI_PRODUCT_SHA256)
        current = product_icon(b"mask")
        self.assertIn(NTP_MARKER.encode(), current)
        self.assertEqual(replace_product_icon(b"before" + ORIGINAL_ICON + b"after", current),
                         b"before" + current + b"after")

    def test_marked_icon_updated_with_current_mask(self):
        current = product_icon(b"new mask")
        self.assertEqual(replace_product_icon(product_icon(b"old mask"), current), current)
        self.assertEqual(replace_product_icon(current, current), current)

    def test_unknown_icon_raises(self):
        with self.assertRaisesRegex(ValueError, "Unrecognized phi-product definition"):
            replace_product_icon(b'<g id="phi-product"><path/></g>', product_icon(b"mask"))

    def test_every_definition_checked(self):
        with self.assertRaises(ValueError):
            replace_product_icon(ORIGINAL_ICON + b'<g id="phi-product">unknown</g>', product_icon(b"mask"))
        current = product_icon(b"mask")
        self.assertEqual(replace_product_icon(ORIGINAL_ICON * 2, current), current * 2)

    def test_icon_inherits_fill(self):
        icon = ET.fromstring(product_icon(b"mask"))
        self.assertEqual(icon.get("viewBox"), "0 0 24 24")
        self.assertEqual(icon.find("mask").get("style"), "mask-type:alpha")
        for element in icon.iter():
            self.assertNotIn("fill", element.attrib)

    def test_scan_skips_brotli_and_handles_raw_and_gzip(self):
        skipped = BROTLI + b"deliberately not decodable"
        pak = Pak(fixture(0, [(1, skipped), (2, ORIGINAL_ICON),
                              (3, compress(b"bundle" + ORIGINAL_ICON, "gzip"))]))
        self.assertEqual(patch_product_icons(pak, b"mask"), 2)
        self.assertEqual(pak.resources[1], skipped)
        self.assertEqual(pak.decoded(2), product_icon(b"mask"))
        self.assertEqual(pak.decoded(3), b"bundle" + product_icon(b"mask"))
        reparsed = Pak(pak.to_bytes())
        self.assertEqual(patch_product_icons(reparsed, b"mask"), 2)
        self.assertFalse(reparsed.changed)

    def test_no_definition_anywhere_raises(self):
        self.assertIsNone(replace_product_icon(b"no icon", product_icon(b"mask")))
        pak = Pak(fixture(0, [(1, b"no icon"), (2, BROTLI + b"skip")]))
        with self.assertRaisesRegex(ValueError, "No resource defines phi-product"):
            patch_product_icons(pak, b"mask")


if __name__ == "__main__":
    unittest.main()
