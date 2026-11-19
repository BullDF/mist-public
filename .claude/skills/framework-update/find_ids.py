"""Find where rebrand_framework.py's targets live in a new framework.

Usage: python3 -I find_ids.py "<framework>/Versions/Current/Resources"

Matches every non-Brotli resource by the original hashes and markers in
mist/scripts/rebrand_framework.py, and prints each constant whose ID moved.
A target it can't find changed content: inspect it by hand.
"""

import hashlib
from pathlib import Path
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "mist/scripts"))
import rebrand_framework as rf  # noqa: E402
from pak import BROTLI, Pak  # noqa: E402


def scan(pak):
    """sha256 -> ids, plus each decoded non-Brotli resource."""
    hashes, decoded = {}, {}
    for rid in sorted(pak.resources):
        if pak.resources[rid].startswith(BROTLI):
            continue
        data = pak.decoded(rid)
        decoded[rid] = data
        hashes.setdefault(hashlib.sha256(data).hexdigest(), []).append(rid)
    return hashes, decoded


def report(name, old, new):
    if not new:
        print(f"{name}: NOT FOUND (was {old}); content changed, inspect by hand")
    elif old in new:
        print(f"{name}: {old} unchanged")
    else:
        print(f"{name}: {old} -> {', '.join(map(str, new))}  CHANGE")


def main():
    resources = Path(sys.argv[1])
    hashes, decoded = scan(Pak.read(resources / "resources.pak"))
    report("NTP_LOGO_ID", rf.NTP_LOGO_ID, hashes.get(rf.NTP_LOGO_SHA256, []))
    report("NTP_PAGE_ID", rf.NTP_PAGE_ID, [rid for rid, d in decoded.items()
                                          if b"url(./icons/phi_logo.svg)" in d and b'class="phi-logo"' in d])
    report("NTP_SHELL_ID", rf.NTP_SHELL_ID, [rid for rid, d in decoded.items()
                                            if b"<ntp-app></ntp-app>" in d and b"new_tab_page.js" in d])
    report("GAMES_PAGE_ID", rf.GAMES_PAGE_ID, [rid for rid, d in decoded.items() if b'id="phi-games-js"' in d])
    for rid, (sha, *_) in rf.SVG_TARGETS.items():
        report(f"SVG_TARGETS {rid}", rid, hashes.get(sha, []))
    products = [m for d in decoded.values() for m in rf.PHI_PRODUCT.finditer(d)]
    unknown = sum(hashlib.sha256(m.group()).hexdigest() != rf.PHI_PRODUCT_SHA256 for m in products)
    print(f"phi-product: {len(products)} definitions, {unknown} with an unknown hash")
    for pack in ("chrome_100_percent.pak", "chrome_200_percent.pak"):
        hashes, _ = scan(Pak.read(resources / pack))
        for (target, rid), (sha, filename) in rf.PNG_TARGETS.items():
            if target == pack:
                report(f"PNG_TARGETS {pack} {rid} ({filename})", rid, hashes.get(sha, []))


if __name__ == "__main__":
    main()
