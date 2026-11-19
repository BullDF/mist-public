"""Rebrand native resources and the built app's approved framework resource packs, and stamp the framework's release tag."""

from pathlib import Path
import json
import plistlib
import re
import subprocess
import sys
import tempfile
import time

from rebrand_framework import rebrand_framework


REPO = Path(__file__).resolve().parents[2]
# Written by scripts/download_phi_framework.sh; the About window shows it.
FRAMEWORK_RELEASE = REPO / "Frameworks/PhiFrameworkRelease"
PHI =re.compile(r"(?<![A-Za-z])Phi(?![A-Za-z])")
FORMAT_KEYS = {"NSStringFormatSpecTypeKey", "NSStringFormatValueTypeKey"}
SWIFT_LITERAL = r'"((?:[^"\\]|\\.)*)"'
# Localized Swift calls with a literal key; the fallback is the value, or the key when there is none.
LOCALIZED_CALLS = (
    re.compile(rf"NSLocalizedString\(\s*{SWIFT_LITERAL}\s*,\s*(?:value:\s*{SWIFT_LITERAL}|comment:)"),
    re.compile(rf"String\(\s*localized:\s*{SWIFT_LITERAL}(?:\s*,\s*defaultValue:\s*{SWIFT_LITERAL})?"),
)


def rewrite(value, stringsdict=False):
    if isinstance(value, str):
        return PHI.sub("Mist", value.replace("Phi Browser", "Mist"))
    if isinstance(value, dict):
        return {
            key: item if stringsdict and key in FORMAT_KEYS else rewrite(item, stringsdict)
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [rewrite(item, stringsdict) for item in value]
    return value


def read_plist(path):
    try:
        data = path.read_bytes()
        if data.startswith((b"\xff\xfe", b"\xfe\xff")):
            # Xcode emits UTF-16 bytes with an unchanged UTF-8 XML declaration.
            xml = data.decode("utf-16")
            xml = re.sub(r'(<\?xml[^>]*encoding=[\"\'])[^\"\']+', r'\g<1>UTF-8', xml, count=1)
            data = xml.encode("utf-8")
        return plistlib.loads(data)
    except Exception as error:
        raise ValueError(f"Cannot parse plist {path}: {error}") from error


def write_plist(path, value):
    path.write_bytes(plistlib.dumps(value, fmt=plistlib.FMT_XML, sort_keys=False))
    subprocess.run(["/usr/bin/plutil", "-lint", str(path)], check=True, stdout=subprocess.DEVNULL)


def mark_translated(node):
    if isinstance(node, dict):
        if "stringUnit" in node:
            node["stringUnit"]["state"] = "translated"
        for item in node.values():
            mark_translated(item)


def compiled_english(resources):
    """Return every English catalog value as en.lproj tables, merged with what the build emitted.

    xcstringstool leaves English entries marked new out of en.lproj, so the app shows the Swift
    or Info.plist fallback instead, which can say Phi and which no resource rewrite reaches.
    """
    tables = {}
    with tempfile.TemporaryDirectory() as temp:
        temp = Path(temp)
        for catalog_path in sorted((REPO / "Resources").glob("*.xcstrings")):
            catalog = json.loads(catalog_path.read_text())
            if catalog.get("sourceLanguage") != "en":
                raise ValueError(f"Expected English source language in {catalog_path}")
            for entry in catalog["strings"].values():
                mark_translated(entry.get("localizations", {}).get("en"))
            source = temp / catalog_path.name
            source.write_text(json.dumps(catalog, ensure_ascii=False))
            subprocess.run(
                ["/usr/bin/xcrun", "xcstringstool", "compile", str(source), "--output-directory", str(temp), "--language", "en"],
                check=True,
            )
        for path in sorted((temp / "en.lproj").iterdir()):
            target = resources / "en.lproj" / path.name
            tables[target] = {**read_plist(path), **(read_plist(target) if target.exists() else {})}
    return tables


def named(path, value, name):
    """Gives a localized InfoPlist.strings the build's own name: the catalog's would name Dev and the tests Mist in
    crash reports and the Dock."""
    if path.name == "InfoPlist.strings":
        for key in ("CFBundleName", "CFBundleDisplayName"):
            if key in value:
                value[key] = name
    return value


def unbranded_fallbacks(english_keys):
    """Yield Swift calls whose fallback says Phi and that have no English entry to rebrand."""
    for path in sorted((REPO / "Sources").rglob("*.swift")):
        text = path.read_text()
        for pattern in LOCALIZED_CALLS:
            for match in pattern.finditer(text):
                key, fallback = match.group(1), match.group(2) or match.group(1)
                if key not in english_keys and rewrite(fallback) != fallback:
                    line = text.count("\n", 0, match.start()) + 1
                    yield f"{path.relative_to(REPO)}:{line} {key}"


def main():
    started = time.perf_counter()
    if len(sys.argv) != 2:
        raise ValueError("Usage: rebrand_app.sh <path-to-.app>")
    app = Path(sys.argv[1]).resolve()
    info_path = app / "Contents/Info.plist"
    info = read_plist(info_path)
    bundle_id = info.get("CFBundleIdentifier")
    if bundle_id not in {"com.bulldf.mist", "com.bulldf.mist.dev", "com.bulldf.mist.tests"}:
        raise ValueError(f"Refusing to rebrand non-Mist app: {app}")
    name = {
        "com.bulldf.mist": "Mist",
        "com.bulldf.mist.dev": "Mist Dev",
        "com.bulldf.mist.tests": "Mist Tests",
    }[bundle_id]
    info["CFBundleName"] = info["CFBundleDisplayName"] = name
    # macOS releases are tagged mac-vX.Y.Z since 2.17.0; About shows vX.Y.Z.
    release = FRAMEWORK_RELEASE.read_text().strip().removeprefix("mac-") if FRAMEWORK_RELEASE.is_file() else ""
    if release:
        info["PhiFrameworkRelease"] = release
    else:
        info.pop("PhiFrameworkRelease", None)
        print(f"warning: no {FRAMEWORK_RELEASE.relative_to(REPO)}; rerun scripts/download_phi_framework.sh to show the framework release in About")
    resources = app / "Contents/Resources"
    if not resources.is_dir():
        raise ValueError(f"Missing app resources: {resources}")
    pending = [(info_path, info)]
    english = compiled_english(resources)
    english_keys = set().union(
        *(english.get(resources / "en.lproj" / name, {}) for name in ("Localizable.strings", "Localizable.stringsdict"))
    )
    leaks = list(unbranded_fallbacks(english_keys))
    if leaks:
        raise ValueError("English fallbacks say Phi but are missing from Resources/Localizable.xcstrings:\n" + "\n".join(leaks))
    for path in sorted(resources.rglob("*")):
        if path.suffix not in {".strings", ".stringsdict"} or not path.parent.name.endswith(".lproj"):
            continue
        if not path.resolve().is_relative_to(resources.resolve()):
            raise ValueError(f"Localized resource points outside Resources: {path}")
        value = english.pop(path) if path in english else read_plist(path)
        pending.append((path, named(path, rewrite(value, path.suffix == ".stringsdict"), name)))
    # Tables the build left out of en.lproj because none of their English entries were translated.
    for path, value in english.items():
        pending.append((path, named(path, rewrite(value, path.suffix == ".stringsdict"), name)))
    # Parse all resources before changing any file, so malformed input fails clearly.
    for path, value in pending:
        write_plist(path, value)
    print(f"Rebranded Mist Info.plist and {len(pending) - 1} localized plists")
    rebrand_framework(app)
    print(f"Mist rebrand completed in {time.perf_counter() - started:.2f}s")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"error: Mist rebrand failed: {error}", file=sys.stderr)
        sys.exit(1)
