#!/bin/bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

readonly test_bundle_id=com.bulldf.mist.tests
readonly derived_data="$repo_root/build/DerivedData-Tests"
parallel=NO
keep_state=NO
extra_args=()
for argument in "$@"; do
    case "$argument" in
        --parallel) parallel=YES ;;
        --keep-state) keep_state=YES ;;
        --help|-h)
            echo "Usage: mist/scripts/test.sh [--parallel] [--keep-state] [extra xcodebuild args...]"
            exit 0
            ;;
        -project|-workspace|-scheme|-target|-alltargets|-configuration|-derivedDataPath|-xctestrun|-testProductsPath|-parallel-testing-enabled|MIST_BUNDLE_ID=*|PRODUCT_BUNDLE_IDENTIFIER=*|build|test|build-for-testing|test-without-building)
            echo "error: test isolation does not permit overriding $argument" >&2
            exit 2
            ;;
        *) extra_args+=("$argument") ;;
    esac
done

build_args=(-project Phi.xcodeproj -scheme PhiBrowser-OpenSource
    -destination platform=macOS -derivedDataPath "$derived_data"
    -testLanguage en -testRegion US
    "MIST_BUNDLE_ID=$test_bundle_id" -parallel-testing-enabled "$parallel")
xcodebuild build-for-testing "${build_args[@]}" ${extra_args[@]+"${extra_args[@]}"}

host_info="$derived_data/Build/Products/OpenSource/Phi.app/Contents/Info.plist"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$host_info")
if [ "$bundle_id" != "$test_bundle_id" ]; then
    echo "error: refusing to test host with bundle identifier '$bundle_id'" >&2
    exit 1
fi

if [ "$keep_state" != YES ]; then
    # Query running apps directly: an Apple event by bundle ID could launch an app.
    /usr/bin/xcrun swift - "$test_bundle_id" <<'SWIFT'
import AppKit
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[1])
for app in apps { app.terminate() }
let deadline = Date().addingTimeInterval(60)
while apps.contains(where: { !$0.isTerminated }) {
    guard Date() < deadline else {
        fputs("error: test host did not quit within 60 seconds\n", stderr)
        exit(1)
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
SWIFT
    # cfprefsd can report the domain and then fail to find it on delete.
    /usr/bin/defaults delete "$test_bundle_id" >/dev/null 2>&1 || true
    /bin/rm -rf -- \
        "$HOME/Library/Application Support/$test_bundle_id" \
        "$HOME/Library/Caches/$test_bundle_id" \
        "$HOME/Library/HTTPStorages/$test_bundle_id" \
        "$HOME/Library/Saved Application State/$test_bundle_id.savedState"
    # Each test launch leaves a throwaway profile under the user temp dir.
    # Other processes' temp dirs can vanish mid-walk; that isn't a failure.
    /usr/bin/find "$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)" -maxdepth 1 -type d \
        -name 'PhiTests-*' -exec /bin/rm -rf -- {} + 2>/dev/null || true
fi

xcodebuild test-without-building "${build_args[@]}" ${extra_args[@]+"${extra_args[@]}"}
