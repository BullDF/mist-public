#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: ${0##*/} <app-path>" >&2
    exit 2
fi

app_path=$1
contents_path="$app_path/Contents"
macos_path="$contents_path/MacOS"
info_plist_path="$contents_path/Info.plist"

if [ ! -d "$app_path" ] || [ ! -d "$macos_path" ] || [ ! -f "$info_plist_path" ]; then
    echo "error: OpenSource app product is incomplete: $app_path" >&2
    exit 1
fi

bundle_identifier=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$info_plist_path" 2>/dev/null || true)
case "$bundle_identifier" in
    com.bulldf.mist|com.bulldf.mist.dev|com.bulldf.mist.tests) ;;
    *)
        echo "error: unexpected OpenSource bundle identifier '$bundle_identifier'" >&2
        exit 1
        ;;
esac

remove_component() {
    component_path=$1
    if [ -e "$component_path" ]; then
        /bin/rm -rf "$component_path"
    fi
    if [ -e "$component_path" ]; then
        echo "error: OpenSource component remains in app product: $component_path" >&2
        exit 1
    fi
}

remove_component "$contents_path/Frameworks/Sparkle.framework"
remove_component "$contents_path/Frameworks/Sentry.framework"
remove_component "$contents_path/Resources/PostHog_PostHog.bundle"
remove_component "$contents_path/Library/LoginItems/Phi Sentinel.app"
remove_component "$contents_path/Library/LoginItems/Sentinel.app"

phi_framework="$contents_path/Frameworks/Phi Framework.framework"
if [ ! -d "$phi_framework" ]; then
    echo "error: required Phi Framework is missing from app product" >&2
    exit 1
fi

sparkle_path=$(/usr/bin/find "$app_path" -iname '*sparkle*' -print -quit)
if [ -n "$sparkle_path" ]; then
    echo "error: Sparkle content remains in app product: $sparkle_path" >&2
    exit 1
fi

sentinel_component_path=$(/usr/bin/find "$app_path" \
    \( -iname '*sentinel*.app' -o -iname '*sentinel*.framework' -o -iname '*sentinel*.bundle' \) \
    -print -quit)
if [ -n "$sentinel_component_path" ]; then
    echo "error: Sentinel component remains in app product: $sentinel_component_path" >&2
    exit 1
fi

phi_framework_linked=NO
for binary_path in "$macos_path"/*; do
    [ -f "$binary_path" ] || continue
    /usr/bin/file "$binary_path" | /usr/bin/grep -q 'Mach-O' || continue

    linked_libraries=$(/usr/bin/otool -L "$binary_path")
    if printf '%s\n' "$linked_libraries" | /usr/bin/grep -q 'Sparkle.framework'; then
        echo "error: Sparkle load command remains in $binary_path" >&2
        exit 1
    fi
    if printf '%s\n' "$linked_libraries" | /usr/bin/grep -q 'Sentry.framework'; then
        echo "error: Sentry load command remains in $binary_path" >&2
        exit 1
    fi
    if printf '%s\n' "$linked_libraries" | /usr/bin/grep -q 'Phi Framework.framework'; then
        phi_framework_linked=YES
    fi

    if /usr/bin/nm -g "$binary_path" 2>/dev/null | /usr/bin/grep -E -q 'SPU|SUAppcast|\$s7Sparkle|_OBJC_(CLASS|METACLASS)_\$_SU'; then
        echo "error: Sparkle symbol remains in $binary_path" >&2
        exit 1
    fi
done

if [ "$phi_framework_linked" != "YES" ]; then
    echo "error: required Phi Framework load command is missing" >&2
    exit 1
fi

for key in \
    SUAutomaticallyUpdate \
    SUEnableAutomaticChecks \
    SUFeedURL \
    SUPublicEDKey \
    SUScheduledCheckInterval
do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$info_plist_path" >/dev/null 2>&1 || true
    if /usr/libexec/PlistBuddy -c "Print :$key" "$info_plist_path" >/dev/null 2>&1; then
        echo "error: Sparkle Info.plist key remains: $key" >&2
        exit 1
    fi
done

/bin/sh "${SRCROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}/mist/scripts/rebrand_app.sh" "$app_path"

# Sign the stub outside the bundle so its signature binds only its bytes and ID,
# not Info.plist or the changing Phi.debug.dylib and other bundle resources.
executable_name=${EXECUTABLE_NAME:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist_path")}
executable_path="$macos_path/$executable_name"
executable_mode=$(/usr/bin/stat -f '%Lp' "$executable_path")
signed_executable=$(/usr/bin/mktemp /tmp/mist-executable.XXXXXX)
trap '/bin/rm -f "${signed_executable:?}" "${executable_path:?}.new"' 0
/bin/cp "$executable_path" "$signed_executable"
/usr/bin/codesign --force --sign - --identifier "$bundle_identifier" "$signed_executable"
/bin/cp "$signed_executable" "$executable_path.new"
/bin/chmod "$executable_mode" "$executable_path.new"
# A new inode also prevents stale kernel signature caches for the test host.
/bin/mv -f "$executable_path.new" "$executable_path"

signature=$(/usr/bin/codesign -dv --verbose=4 "$app_path" 2>&1) || {
    echo "error: could not read OpenSource executable signature" >&2
    exit 1
}
if ! printf '%s\n' "$signature" | /usr/bin/grep -Fxq "Identifier=$bundle_identifier" ||
   ! printf '%s\n' "$signature" | /usr/bin/grep -Fxq 'Sealed Resources=none' ||
   [ -e "$contents_path/_CodeSignature" ]; then
    echo "error: OpenSource executable must use bundle identifier $bundle_identifier without sealing the bundle" >&2
    exit 1
fi
echo "Verified pruned OpenSource product"
