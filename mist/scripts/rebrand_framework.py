"""Patch only the built framework's branding and Crashpad upload URL, and list
the framework's titles for menu items Mist strips."""

from __future__ import annotations

import base64
import hashlib
import os
from pathlib import Path
import plistlib
import re
import subprocess
import time

from pak import BROTLI, Pak


PHI = re.compile(r"(?<![A-Za-z])Phi(?![A-Za-z])")
NTP_LOGO_ID = 21358
NTP_PAGE_ID = 21370
NTP_SHELL_ID = 21368
GAMES_PAGE_ID = 42109
GAMES_HOST = b'<div id="phi-games-host"></div>'
GAMES_BUNDLE = re.compile(rb'(<script type="text/plain" id="phi-games-js">).+?(</script>)', re.DOTALL)
NTP_LOGO_SHA256 = "7a8758f191c76bc2308d68344758937d758b46cb96e638380335374d364f0c2c"
NTP_MARKER = 'data-mist-logo="1"'
PNG_MARKER = b"mist-logo\x001"
PNG_TARGETS = {
    ("chrome_100_percent.pak", 15315): ("3aceda2c5fd5de00457eed36ed3f10f9e68b5dcc56f686a3110ad93089fabcae", "product-logo-32.png"),
    ("chrome_200_percent.pak", 15315): ("86f0a7180b98be39e6a4bd8dcbf750756ecd7f23b8868188fc17c2dde1fd4fc0", "product-logo-64.png"),
    ("chrome_100_percent.pak", 356): ("e0a57722ca9efe17794d2e86c36f7c7e14a5c54bcc3c41722b0cb256dc80f71a", "product-logo-16.png"),
    ("chrome_200_percent.pak", 356): ("3aceda2c5fd5de00457eed36ed3f10f9e68b5dcc56f686a3110ad93089fabcae", "product-logo-32.png"),
    ("chrome_100_percent.pak", 15304): ("0be841f2a30dc8cddd1de19247ba6e6f2bfa3d3fc488139793265f3104a78b4f", "swirl-gray-16.png"),
    ("chrome_200_percent.pak", 15304): ("5dcbece03509f273eda67302f604d2f2bc5d9ee9754b6a73dada894abf01e129", "swirl-gray-32.png"),
    ("chrome_100_percent.pak", 42291): ("6f5d760aa5368b7ef3349c957f6f8ab08defb6e91d44bef0d022d1d329293228", "swirl-faint-16.png"),
    ("chrome_200_percent.pak", 42291): ("1e7b76e3538465b80f5b5ee350a1501b22953d2c4a0fa5316dfe354c0cc812ca", "swirl-faint-32.png"),
    ("chrome_100_percent.pak", 42289): ("d42d7f4f157f9a7f17f1ef27124631a68ff0a2aece5411f6981cacda41e13b32", "wordmark-black-78x32.png"),
    ("chrome_200_percent.pak", 42289): ("ac1b8ffc048b5c28cf84a8734161c59b9a7ccb9c2bad1097747636a74b257089", "wordmark-black-155x64.png"),
    ("chrome_100_percent.pak", 42290): ("461ced0be370da3d07814bb2ed5a372554e28f2ebbc975090e2efc5fc472cc9b", "wordmark-white-78x32.png"),
    ("chrome_200_percent.pak", 42290): ("6077a2595dc14725d29e85e4cbfa921877ebe4d8d16c3ed46c02e16cbbc9ccbf", "wordmark-white-155x64.png"),
}
# Original hash, canvas width/height, fill, square side, vertical offset.
SVG_TARGETS = {
    53274: ("04d70869c1bf276cf0ed26ae9e44dc9af2a101434ed8f2fdb0d2a70fd92055d8", 32, 32, "#D2D2D2", 32, 0),
    15163: ("4a27a9381f4ccad1c559b689aaeaf4fc23be4021d4636773e4aa546bf55b7b97", 1024, 1024, "#505050", 1024, 0),
    16197: ("abbea48068feec7cabd1c2e1a29f3ffb294a3b326ff39bfa85c7adb7f5eccb85", 35, 41, "black", 35, 3),
}
PHI_PRODUCT_SHA256 = "8db5c8ab96a2923762f4c47bf06633596d3a4eef8e9a8cb54b0b6175c6a86148"
PHI_PRODUCT = re.compile(rb'<g id="phi-product"[^>]*>.*?</g>', re.DOTALL)
CRASH_UPLOAD_URL = (
    b"https://o4510181852708864.ingest.us.sentry.io/api/4510181889933312/minidump/"
    b"?sentry_key=25f25943199ae1e81dd0dfdf8343aac7"
)
# English framework strings whose menu items MistRemovedMenuItems strips.
REMOVED_MENU_TITLES = ("Open in Kiosk",)
REMOVED_MENU_TITLES_PLIST = "MistRemovedMenuItemTitles.plist"


def blank_crash_upload_url(copy: bytes, source: bytes) -> bytes | None:
    error = "Unrecognized Crashpad upload URL; inspect the new framework before patching"
    if source.count(CRASH_UPLOAD_URL) != 1 or b"sentry.io" in source.replace(CRASH_UPLOAD_URL, b""):
        raise ValueError(error)
    count = copy.count(CRASH_UPLOAD_URL)
    if count == 1:
        start = copy.index(CRASH_UPLOAD_URL)
        end = start + len(CRASH_UPLOAD_URL)
        if start == 0 or end == len(copy) or copy[start - 1] != 0 or copy[end] != 0:
            raise ValueError(error)
        return copy[:start] + b"\0" * len(CRASH_UPLOAD_URL) + copy[end:]
    start = source.index(CRASH_UPLOAD_URL)
    if count == 0 and copy[start:start + len(CRASH_UPLOAD_URL)] == b"\0" * len(CRASH_UPLOAD_URL):
        return None
    raise ValueError(error)


def rewrite_text(text):
    return PHI.sub("Mist", text.replace("Phi Browser", "Mist"))


def patch_locale(pak):
    encoding = {1: "utf-8", 2: "utf-16-le"}.get(pak.encoding)
    if encoding is None:
        return 0, 0
    before = 0
    after = 0
    for resource_id in sorted(pak.resources):
        decoded = pak.decoded(resource_id)
        try:
            text = decoded.decode(encoding)
        except UnicodeDecodeError:
            continue
        if any(ord(character) < 32 and character not in "\t\r\n" for character in text):
            continue
        replacement = rewrite_text(text)
        if resource_id in pak.canonical_ids:
            before += len(PHI.findall(text))
            after += len(PHI.findall(replacement))
        if replacement != text:
            pak.replace(resource_id, replacement.encode(encoding))
    return before, after


def locale_text(pak, resource_id):
    encoding = {1: "utf-8", 2: "utf-16-le"}.get(pak.encoding)
    if encoding is None or resource_id not in pak.resources:
        return None
    try:
        return pak.decoded(resource_id).decode(encoding)
    except UnicodeDecodeError:
        return None


def removed_menu_ids(english):
    ids = []
    for title in REMOVED_MENU_TITLES:
        matches = [resource_id for resource_id in english.resources if locale_text(english, resource_id) == title]
        if len(matches) != 1:
            raise ValueError(f"Framework string {title!r} matched {len(matches)} en.lproj resources; "
                             "update REMOVED_MENU_TITLES")
        ids.extend(matches)
    return ids


def ntp_svg(glyph):
    encoded = base64.b64encode(glyph.read_bytes()).decode("ascii")
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
        f'{NTP_MARKER} width="29.367086" height="34.751049" '
        'viewBox="14.316406 11.624511 29.367086 34.751049" fill="none">\n'
        '<image x="14.316406" y="14.3164925" width="29.367086" height="29.367086" '
        f'xlink:href="data:image/png;base64,{encoded}"/>\n</svg>\n'
    ).encode("utf-8")


def patch_ntp(pak, glyph):
    original = pak.decoded(NTP_LOGO_ID)
    if (NTP_MARKER.encode() not in original
            and hashlib.sha256(original).hexdigest() != NTP_LOGO_SHA256):
        raise ValueError(f"Unrecognized NTP logo resource {NTP_LOGO_ID}; inspect the new framework before patching")
    page = pak.decoded(NTP_PAGE_ID)
    if b"url(./icons/phi_logo.svg)" not in page or b'class="phi-logo"' not in page:
        raise ValueError("Classic NTP no longer references the expected logo")
    pak.replace(NTP_LOGO_ID, ntp_svg(glyph))


def blank_ntp_shell(pak):
    marker = b'data-mist-native-ntp="1"'
    error = "NTP shell changed; inspect the new framework before patching"
    if NTP_SHELL_ID not in pak.resources:
        raise ValueError(error)
    original = pak.decoded(NTP_SHELL_ID)
    if marker in original:
        return
    if b"<ntp-app></ntp-app>" not in original or b"new_tab_page.js" not in original:
        raise ValueError(error)
    pak.replace(NTP_SHELL_ID, (
        '<!doctype html>\n'
        '<html dir="$i18n{textdirection}" lang="$i18n{language}" data-mist-native-ntp="1">\n'
        '  <head>\n'
        '    <meta charset="utf-8">\n'
        '    <title>$i18n{title}</title>\n'
        '    <style>\n'
        '      html, body {\n'
        '        background: $i18n{backgroundColor};\n'
        '        margin: 0;\n'
        '        height: 100%;\n'
        '      }\n'
        '    </style>\n'
        '  </head>\n'
        '  <body></body>\n'
        '</html>\n'
    ).encode("utf-8"))


def strip_offline_games(pak):
    marker = b'data-mist-no-games="1"'
    error = "Offline games page changed; inspect the new framework before patching"
    if GAMES_PAGE_ID not in pak.resources:
        raise ValueError(error)
    original = pak.decoded(GAMES_PAGE_ID)
    if marker in original:
        return
    page, count = GAMES_BUNDLE.subn(rb"\1\2", original)
    # The loader returns early on an empty bundle, and the hidden host keeps
    # the page's getRequiredElement("phi-games-host") working.
    if count != 1 or page.count(GAMES_HOST) != 1 or b"!holder.textContent){return}" not in page:
        raise ValueError(error)
    pak.replace(GAMES_PAGE_ID, page.replace(
        GAMES_HOST, b'<div id="phi-games-host" ' + marker + b' style="display: none"></div>',
    ))


def replace_logo(original, replacement, original_sha256, marker, resource_id, pack):
    if marker not in original and hashlib.sha256(original).hexdigest() != original_sha256:
        raise ValueError(f"Unrecognized Phi logo resource {resource_id} in {pack}; inspect the new framework before patching")
    return replacement


def logo_svg(mask, width, height, fill, side, y):
    encoded = base64.b64encode(mask).decode("ascii")
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" {NTP_MARKER} '
        f'width="{width}" height="{height}" viewBox="0 0 {width} {height}">'
        f'<mask id="mist-logo-mask" maskUnits="userSpaceOnUse" x="0" y="0" '
        f'width="{width}" height="{height}" style="mask-type:alpha">'
        f'<image y="{y}" width="{side}" height="{side}" href="data:image/png;base64,{encoded}"/>'
        f'</mask><rect width="{width}" height="{height}" fill="{fill}" mask="url(#mist-logo-mask)"/>'
        '</svg>\n'
    ).encode("utf-8")


def product_icon(mask):
    encoded = base64.b64encode(mask).decode("ascii")
    return (
        f'<g id="phi-product" viewBox="0 0 24 24" {NTP_MARKER}>'
        '<mask id="mist-product-mask" maskUnits="userSpaceOnUse" x="0" y="0" '
        'width="24" height="24" style="mask-type:alpha">'
        f'<image width="24" height="24" href="data:image/png;base64,{encoded}"/>'
        '</mask><rect width="24" height="24" mask="url(#mist-product-mask)"/></g>'
    ).encode("utf-8")


def replace_product_icon(original, replacement):
    def replace(match):
        definition = match.group()
        if (NTP_MARKER.encode() not in definition
                and hashlib.sha256(definition).hexdigest() != PHI_PRODUCT_SHA256):
            raise ValueError("Unrecognized phi-product definition; inspect the new framework before patching")
        return replacement

    result, count = PHI_PRODUCT.subn(replace, original)
    return result if count else None


def patch_product_icons(pak, mask):
    replacement = product_icon(mask)
    count = 0
    for resource_id in sorted(pak.canonical_ids):
        if pak.resources[resource_id].startswith(BROTLI):
            continue
        patched = replace_product_icon(pak.decoded(resource_id), replacement)
        if patched is not None:
            pak.replace(resource_id, patched)
            count += 1
    if not count:
        raise ValueError("No resource defines phi-product; inspect the new framework before patching")
    return count


def write_pak(path, pak):
    if not pak.changed:
        return
    temporary = path.with_name(path.name + ".mist.tmp")
    try:
        temporary.write_bytes(pak.to_bytes())
        temporary.chmod(path.stat().st_mode & 0o777)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def rebrand_framework(app):
    started = time.perf_counter()
    app = app.resolve()
    source_framework = Path(__file__).resolve().parents[2] / "Frameworks/Phi Framework.framework"
    framework = (app / "Contents/Frameworks/Phi Framework.framework").resolve()
    resources = (framework / "Versions/Current/Resources").resolve()
    binary = (framework / "Versions/Current/Phi Framework").resolve()
    for path in (framework, resources, binary):
        if not path.is_relative_to(app) or path.is_relative_to(source_framework.resolve()):
            raise ValueError("Refusing to patch a framework outside the app or in the source tree")
    glyph = Path(__file__).resolve().parents[1] / "brand/glyph.png"
    resource_path = resources / "resources.pak"
    if not resource_path.resolve().is_relative_to(app):
        raise ValueError("resources.pak points outside the app")
    pak = Pak.read(resource_path)
    patch_ntp(pak, glyph)
    blank_ntp_shell(pak)
    strip_offline_games(pak)
    assets = glyph.parent / "framework"
    mask = (assets / "glyph-mask.png").read_bytes()
    bundles = patch_product_icons(pak, mask)
    for resource_id, (original_hash, *canvas) in SVG_TARGETS.items():
        pak.replace(resource_id, replace_logo(
            pak.decoded(resource_id), logo_svg(mask, *canvas), original_hash,
            NTP_MARKER.encode(), resource_id, resource_path.name,
        ))
    write_pak(resource_path, pak)
    del pak

    for pack in ("chrome_100_percent.pak", "chrome_200_percent.pak"):
        path = resources / pack
        if not path.resolve().is_relative_to(app):
            raise ValueError(f"{pack} points outside the app")
        pak = Pak.read(path)
        for (target_pack, resource_id), (original_hash, filename) in PNG_TARGETS.items():
            if target_pack == pack:
                pak.replace(resource_id, replace_logo(
                    pak.decoded(resource_id), (assets / filename).read_bytes(),
                    original_hash, PNG_MARKER, resource_id, pack,
                ))
        write_pak(path, pak)
    print(f"Replaced {len(PNG_TARGETS) + len(SVG_TARGETS)} Phi logo resources and cr:phi-product in {bundles} bundles")

    paths = sorted(resources.glob("*.lproj/locale.pak"))
    if not paths:
        raise ValueError("No framework locale packs found")
    menu_ids = removed_menu_ids(Pak.read(resources / "en.lproj/locale.pak"))
    menu_titles = set()
    changed = 0
    for path in paths:
        if not path.resolve().is_relative_to(app):
            raise ValueError(f"Locale pack points outside the app: {path}")
        pak = Pak.read(path)
        before, after = patch_locale(pak)
        changed += pak.changed
        write_pak(path, pak)
        menu_titles.update(filter(None, (locale_text(pak, resource_id) for resource_id in menu_ids)))
        if path.parent.name in {"fr.lproj", "en.lproj", "en_GB.lproj"}:
            print(f"Mist framework {path.parent.name}: Phi occurrences {before} -> {after}")
    (app / "Contents/Resources" / REMOVED_MENU_TITLES_PLIST).write_bytes(plistlib.dumps(sorted(menu_titles)))
    print(f"Listed {len(menu_titles)} titles of removed framework menu items")

    patched = blank_crash_upload_url(
        binary.read_bytes(), (source_framework / "Versions/Current/Phi Framework").read_bytes(),
    )
    if patched is not None:
        temporary = binary.with_name(binary.name + ".mist.tmp")
        try:
            temporary.write_bytes(patched)
            temporary.chmod(binary.stat().st_mode & 0o777)
            temporary.replace(binary)
        finally:
            temporary.unlink(missing_ok=True)
    subprocess.run([
        "/usr/bin/codesign", "--force", "--sign",
        os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or "-",
        "--preserve-metadata=identifier,entitlements,flags,runtime", str(framework),
    ], check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(framework)], check=True)
    status = " (already blanked)" if patched is None else ""
    print(f"Blanked Crashpad upload URL{status} and re-signed framework")
    print(f"Rebranded framework NTP SVG {NTP_LOGO_ID}; {changed}/{len(paths)} locale packs changed "
          f"in {time.perf_counter() - started:.2f}s")
