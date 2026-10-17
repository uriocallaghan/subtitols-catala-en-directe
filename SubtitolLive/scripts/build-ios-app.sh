#!/bin/zsh
# Builds the iPhone app for the iOS Simulator and opens it there with Catalan ready to
# install from the local packs.
#   ./scripts/build-ios-app.sh            build, install and launch on "iPhone 17 Pro"
#   ./scripts/build-ios-app.sh --no-run   build only
# App Store builds are archived from Xcode (SubtitolLive/iOS/SubtitolLiveiOS.xcodeproj,
# scheme SubtitolLiveiOS, Product > Archive), which signs with the team's account.
set -euo pipefail

script_directory="${0:A:h}"
package_directory="${script_directory:h}"
project_directory="${package_directory:h}"
ios_directory="$package_directory/iOS"
derived="$project_directory/.work/ios-derived"
device="${IOS_SIMULATOR:-iPhone 17 Pro}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ ! -d "$package_directory/Vendor/RuntimeiOS/NemoSpeechRuntime.xcframework" ]]; then
    "$script_directory/build-ios-runtime.sh"
fi
if [[ ! -d "$project_directory/.work/ios-stage/veus-segmentacio" || ! -d "$project_directory/.work/ios-packs" ]]; then
    "$script_directory/stage-ios-resources.sh"
fi
if ! command -v xcodegen >/dev/null; then
    echo "Missing xcodegen: brew install xcodegen" >&2
    exit 1
fi

(cd "$ios_directory" && xcodegen generate --quiet)
# A failed build must stop here: the previous build's app is still in DerivedData.
log="$(mktemp -t build-ios-app)"
if ! xcodebuild \
    -project "$ios_directory/SubtitolLiveiOS.xcodeproj" \
    -scheme SubtitolLiveiOS \
    -destination "platform=iOS Simulator,name=$device" \
    -derivedDataPath "$derived" \
    build > "$log" 2>&1; then
    grep -E "error:|xcodebuild: error" "$log" | head -20 >&2
    echo "Build failed (full log: $log)" >&2
    exit 1
fi
grep -E "warning: " "$log" | sort -u | head -20 || true

app="$derived/Build/Products/Debug-iphonesimulator/SubtitolLive.app"
[[ -d "$app" ]] || { echo "Build failed" >&2; exit 1; }

# Simulator builds are signed ad hoc, without the team. Shortcuts then cannot identify
# the app ("Unable to get teamId" in linkd's log) and hands it no choice from a list:
# a shortcut's format arrives empty and falls back to the default. Signing it again with
# the team's development certificate makes it behave as on a phone.
identity="$(security find-identity -v -p codesigning | awk -F '"' '/Apple Development/ { print $2; exit }')"
entitlements="$derived/Build/Intermediates.noindex/SubtitolLiveiOS.build/Debug-iphonesimulator/SubtitolLiveiOS.build/SubtitolLive.app.xcent"
if [[ -n "$identity" && -f "$entitlements" ]]; then
    for extension in "$app"/Extensions/*.appex(N) "$app"/PlugIns/*.appex(N); do
        codesign --force --sign "$identity" --timestamp=none "$extension" 2>/dev/null
    done
    codesign --force --sign "$identity" --timestamp=none --entitlements "$entitlements" "$app" 2>/dev/null
else
    echo "warning: no Apple Development certificate: Shortcuts' lists will not reach the app in the simulator" >&2
fi
[[ "${1:-}" == "--no-run" ]] && exit 0

xcrun simctl boot "$device" 2>/dev/null || true
open -a Simulator
xcrun simctl install "$device" "$app"
SIMCTL_CHILD_SUBTITOL_PACKS_DIR="$project_directory/.work/ios-packs" \
    xcrun simctl launch "$device" com.uriocallaghan.duna
