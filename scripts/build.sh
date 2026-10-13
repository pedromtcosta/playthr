#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
case "$configuration" in release|debug) ;; *) echo "Usage: bash scripts/build.sh [release|debug]" >&2; exit 2 ;; esac
swift build --disable-sandbox --configuration "$configuration" --scratch-path .build
binary_directory="$(swift build --disable-sandbox --configuration "$configuration" --scratch-path .build --show-bin-path)"
bundle="$PWD/.build/Playthr.app"
identifier="com.playthr.studio"
if [[ "$configuration" == debug ]]; then
    bundle="$PWD/.build/Playthr-Debug.app"
    identifier="com.playthr.studio.debug"
fi
# Stage a fresh bundle: never truncate the executable of a running app.
stage="$(mktemp -d "$PWD/.build/package.XXXXXX")"
staged_bundle="$stage/Playthr.app"
mkdir -p "$staged_bundle/Contents/MacOS" "$staged_bundle/Contents/Resources"
cp "$binary_directory/Playthr" "$staged_bundle/Contents/MacOS/Playthr"
cp Resources/Info.plist "$staged_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $identifier" "$staged_bundle/Contents/Info.plist"
codesign --force --sign - --identifier "$identifier" "$staged_bundle"
if [[ -d "$bundle" ]]; then mv "$bundle" "$stage/previous.app"; fi
mv "$staged_bundle" "$bundle"
echo "Built $bundle"
