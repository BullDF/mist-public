#!/bin/bash
set -euo pipefail
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd)
cd "$repo_root"

dev=NO
seed=NO
launch=YES
for argument in "$@"; do
    case "$argument" in
        --dev) dev=YES ;;
        --seed) seed=YES ;;
        --no-launch) launch=NO ;;
        *) echo "Usage: mist/scripts/install.sh [--dev] [--seed] [--no-launch]" >&2; exit 2 ;;
    esac
done
if [ "$seed" = YES ] && [ "$dev" != YES ]; then
    echo "error: --seed requires --dev" >&2
    exit 2
fi

main_path=/Applications/Mist.app
legacy_main_path="$HOME/Applications/Mist.app"
bundle_id=com.bulldf.mist
executable_name=Mist
app_path="$main_path"
derived_data=build/DerivedData-OpenSource
if [ "$dev" = YES ]; then
    bundle_id=com.bulldf.mist.dev
    executable_name='Mist Dev'
    app_path='/Applications/Mist Dev.app'
    derived_data=build/DerivedData-Dev
fi

# Installed builds are optimized; test.sh keeps the configuration's unoptimized,
# testable, coverage-instrumented settings. The app's code must stay in Phi.debug.dylib
# behind Xcode's stub executable, which is identical across builds: its ad-hoc cdhash
# is what the keychain (Chromium's Safe Storage key) and privacy grants trust, so a
# changing executable would prompt for the keychain password after every install.
# Xcode splits only when SWIFT_OPTIMIZATION_LEVEL is -Onone, so -O is appended to the
# Swift flags instead, where the last optimization flag wins. Whole-module optimization
# would make every one-file rebuild a full recompile.
xcodebuild build -project Phi.xcodeproj -scheme PhiBrowser-OpenSource \
    -destination 'platform=macOS' -derivedDataPath "$derived_data" \
    "MIST_BUNDLE_ID=$bundle_id" \
    'OTHER_SWIFT_FLAGS=$(inherited) -O' GCC_OPTIMIZATION_LEVEL=s DEAD_CODE_STRIPPING=YES \
    ENABLE_TESTABILITY=NO CLANG_COVERAGE_MAPPING=NO

built_app="$repo_root/$derived_data/Build/Products/OpenSource/Phi.app"
built_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$built_app/Contents/Info.plist")
if [ "$built_id" != "$bundle_id" ]; then
    echo "error: expected $bundle_id, built $built_id; installation stopped" >&2
    exit 1
fi
if [ ! -f "$built_app/Contents/MacOS/Phi.debug.dylib" ]; then
    echo "error: build has no Phi.debug.dylib, so the executable would change every install; installation stopped" >&2
    exit 1
fi

# Match the installed bundle's executable path, falling back to Phi for older copies.
mist_pids() {
    local installed_executable
    installed_executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$1/Contents/Info.plist" 2>/dev/null) || installed_executable=Phi
    /bin/ps -axo pid=,comm= | /usr/bin/awk -v executable="$1/Contents/MacOS/$installed_executable" \
        '{ pid=$1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, ""); if ($0 == executable) print pid }'
}
quit_app() {
    if [ -n "$(mist_pids "$1")" ]; then
        /usr/bin/osascript -e "tell application id \"$2\" to quit"
        local attempts=0
        while [ -n "$(mist_pids "$1")" ]; do
            attempts=$((attempts + 1))
            if [ "$attempts" -ge 60 ]; then
                echo "error: $1 did not quit within 60 seconds; installation stopped" >&2
                return 1
            fi
            sleep 1
        done
    fi
}

# Install an exit trap before quitting main, so failed copies also restore it.
relaunch_main_path=''
seed_scratch=''
cleanup() {
    local result=$?
    trap - EXIT
    set +e
    if [ -n "$seed_scratch" ]; then rm -rf -- "$seed_scratch"; fi
    if [ -n "$relaunch_main_path" ]; then
        /usr/bin/open "$relaunch_main_path" || result=1
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

quit_app "$app_path" "$bundle_id"
if [ "$seed" = YES ]; then
    main_data="$HOME/Library/Application Support/com.bulldf.mist"
    dev_data="$HOME/Library/Application Support/com.bulldf.mist.dev"
    if [ ! -d "$main_data" ] || [ -L "$main_data" ] || [ -L "$dev_data" ]; then
        echo "error: seeding requires a main data directory and no data-directory symlinks" >&2
        exit 1
    fi
    for candidate in "$main_path" "$legacy_main_path"; do
        if [ -n "$(mist_pids "$candidate")" ]; then
            relaunch_main_path="$candidate"
            quit_app "$candidate" com.bulldf.mist
        fi
    done
    seed_scratch=$(mktemp -d "${TMPDIR:-/tmp}/mist-dev-seed.XXXXXX")
    # Stage the copy before replacing Dev. -rlpt copies data and safe links,
    # but deliberately omits -D (devices and sockets) from rsync's -a flags.
    /usr/bin/rsync -rlpt --safe-links \
        --exclude='/MistPasswords/' \
        --exclude='/MistSync/' \
        --exclude='SingletonLock' --exclude='SingletonSocket' --exclude='SingletonCookie' \
        --exclude='RunningChromeVersion' --exclude='CDPAgentSocket' \
        --exclude='DevToolsActivePort' --exclude='LOCK' \
        --exclude='/Crashpad/' --exclude='/Phi/PhiLogs/' \
        --exclude='BrowserMetrics*' --exclude='*-journal' \
        "$main_data/" "$seed_scratch/data/"
    /usr/bin/defaults export com.bulldf.mist - | /usr/bin/defaults import com.bulldf.mist.dev -
    # App paths, OS bookmarks, agent consent and telemetry belong to one install.
    for key in LastRunAppBundlePath NSOSPLastRootDirectory \
        PhiCDPRememberedAgentGrants PhiCDPAllAgentsGranted PhiCDPAgentIdentityLabels PhiCDPAgentDenials \
        metrics.contentBlocking.switchesByProfile metrics.firstTimeActions.recorded; do
        if /usr/bin/defaults read com.bulldf.mist.dev "$key" >/dev/null 2>&1; then
            /usr/bin/defaults delete com.bulldf.mist.dev "$key"
        fi
    done
    rm -rf -- "$dev_data"
    /usr/bin/ditto "$seed_scratch/data" "$dev_data"
    if [ -n "$relaunch_main_path" ]; then
        /usr/bin/open "$relaunch_main_path"
        relaunch_main_path=''
    fi
fi

if [ "$dev" != YES ] && [ -e "$legacy_main_path" ]; then
    quit_app "$legacy_main_path" com.bulldf.mist
    rm -rf -- "$legacy_main_path"
fi
rm -rf -- "$app_path"
/usr/bin/ditto "$built_app" "$app_path"
# Strip only the installed copy, so the debugger keeps DerivedData's symbols.
/usr/bin/xcrun strip -x "$app_path/Contents/MacOS/Phi.debug.dylib"
mv "$app_path/Contents/MacOS/Phi" "$app_path/Contents/MacOS/$executable_name"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $executable_name" "$app_path/Contents/Info.plist"
signature=$(/usr/bin/codesign -dv --verbose=4 "$app_path" 2>&1) || {
    echo "error: could not read installed executable signature; installation stopped" >&2
    exit 1
}
if ! printf '%s\n' "$signature" | /usr/bin/grep -Fxq "Identifier=$bundle_id"; then
    echo "error: installed executable signature must use $bundle_id; installation stopped" >&2
    exit 1
fi
touch "$app_path"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app_path"
if [ "$launch" = YES ]; then
    /usr/bin/open "$app_path"
fi
