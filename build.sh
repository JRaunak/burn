#!/bin/bash
# Usage: ./build.sh [install]
# BURN_VERSION=0.2 sets the version; without it, the latest git tag does.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
bin="$(swift build -c release --show-bin-path)/Burn"

app=build/Burn.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Burn"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/pricing.json "$app/Contents/Resources/pricing.json"
cp Resources/Burn.icns "$app/Contents/Resources/Burn.icns"
# Full Xcode can compile the Liquid Glass icon; the Command Line Tools can't, so the .icns stands in.
# actool in some Xcode 26 releases crashes on .icon files, which also falls back to the .icns.
if xcrun --find actool >/dev/null 2>&1; then
    if xcrun actool Resources/Burn.icon --compile "$app/Contents/Resources" --platform macosx \
        --minimum-deployment-target 14.0 --app-icon Burn --include-all-app-icons \
        --output-partial-info-plist build/icon.plist >/dev/null; then
        /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string Burn" "$app/Contents/Info.plist"
    else
        echo "actool failed; using Resources/Burn.icns" >&2
        cp Resources/Burn.icns "$app/Contents/Resources/Burn.icns"
    fi
fi
# Otherwise a local build reports Info.plist's 0.1 and the updater always offers an update.
version="${BURN_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || true)}"
if [ -n "$version" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${version#v}" "$app/Contents/Info.plist"
fi
codesign --force --sign - "$app"
echo "built $app"

if [ "${1:-}" = install ]; then
    mkdir -p "$HOME/Applications"
    pkill -x Burn 2>/dev/null || true
    # open would just activate the old process if it's still exiting.
    while pgrep -x Burn >/dev/null; do sleep 0.1; done
    rm -rf "$HOME/Applications/Burn.app"
    cp -R "$app" "$HOME/Applications/"
    open "$HOME/Applications/Burn.app"
    echo "installed to ~/Applications/Burn.app"
fi
