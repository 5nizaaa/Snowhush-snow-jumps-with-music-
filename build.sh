#!/bin/zsh
# Builds build/Snowhush.app for Apple silicon and Intel.
# Signs ad hoc for local use; set IDENTITY to a "Developer ID Application" identity for a release build.
set -euo pipefail
cd "$(dirname "$0")"

flags=(-c release --arch arm64 --arch x86_64)
swift build "${flags[@]}"
products="$(swift build "${flags[@]}" --show-bin-path)"

app=build/Snowhush.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$products/Snowhush" "$app/Contents/MacOS/"
ditto "$products/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
cp Resources/Info.plist "$app/Contents/"
cp Resources/AppIcon.icns "$app/Contents/Resources/"

if [[ -n "${IDENTITY:-}" ]]; then
    # Sparkle's helpers are signed inside out, each with the hardened runtime, as notarization requires.
    sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
    sign=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
    "${sign[@]}" "$sparkle/XPCServices/Installer.xpc"
    "${sign[@]}" --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
    "${sign[@]}" "$sparkle/Autoupdate"
    "${sign[@]}" "$sparkle/Updater.app"
    "${sign[@]}" "$app/Contents/Frameworks/Sparkle.framework"
    "${sign[@]}" "$app"
else
    codesign --force --deep --sign - "$app"
fi
codesign --verify --deep --strict "$app"
echo "Built $app"
