#!/bin/bash
# Installs the latest Burn release into ~/Applications.
#   curl -fsSL https://raw.githubusercontent.com/JRaunak/burn/master/install.sh | bash
# curl doesn't set the quarantine flag, so Gatekeeper doesn't block the unsigned app.
# If the prebuilt app can't be downloaded (Intel Mac, or a network that blocks GitHub's
# release-asset host), it builds the same release from source instead.
set -euo pipefail

repo="JRaunak/burn"
dest="$HOME/Applications"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

prebuilt() {
    [ "$(uname -m)" = arm64 ] || return 1
    local url="https://github.com/$repo/releases/latest/download/Burn.tar.gz"
    echo "Downloading $url"
    curl -fsSL --connect-timeout 15 --max-time 120 "$url" -o "$tmp/Burn.tar.gz" &&
        tar -xzf "$tmp/Burn.tar.gz" -C "$tmp" &&
        [ -d "$tmp/Burn.app" ]
}

from_source() {
    if ! xcode-select -p >/dev/null 2>&1; then
        echo "Building from source needs the Command Line Tools. Run: xcode-select --install" >&2
        exit 1
    fi
    # github.com/<repo>/releases/latest redirects to .../releases/tag/<tag>.
    local tag
    tag="$(curl -fsSI "https://github.com/$repo/releases/latest" | awk -F/ 'tolower($1) ~ /^location:/ {print $NF}' | tr -d '\r')"
    [ -n "$tag" ] || { echo "Couldn't find the latest release tag" >&2; exit 1; }
    echo "Building $tag from source"
    mkdir "$tmp/src"
    curl -fsSL "https://codeload.github.com/$repo/tar.gz/refs/tags/$tag" | tar -xz -C "$tmp/src" --strip-components 1
    BURN_VERSION="${tag#v}" "$tmp/src/build.sh"
    mv "$tmp/src/build/Burn.app" "$tmp/Burn.app"
}

if ! prebuilt; then
    rm -rf "$tmp/Burn.app"
    echo "Prebuilt download unavailable; falling back to a source build."
    from_source
fi

mkdir -p "$dest"
pkill -x Burn 2>/dev/null || true
while pgrep -x Burn >/dev/null; do sleep 0.1; done
rm -rf "$dest/Burn.app"
mv "$tmp/Burn.app" "$dest/"
open "$dest/Burn.app"
echo "Installed $dest/Burn.app"
