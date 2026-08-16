#!/bin/bash
# SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
# SPDX-License-Identifier: GPL-2.0-only

# Validates the assembled app, its embedded screensaver, and their signatures.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APP_PATH="${1:-$REPO_ROOT/dist/NES Wallpaper.app}"
APP_PLIST="$APP_PATH/Contents/Info.plist"
SAVER_PATH="$APP_PATH/Contents/Resources/NES Wallpaper.saver"
SAVER_PLIST="$SAVER_PATH/Contents/Info.plist"

test -x "$APP_PATH/Contents/MacOS/NESWallpaper"
test -x "$APP_PATH/Contents/MacOS/nes-helper"
test -x "$SAVER_PATH/Contents/MacOS/NESWallpaperSaver"
test -s "$APP_PATH/Contents/Resources/LICENSE"
test -s "$APP_PATH/Contents/Resources/SOURCE.md"
test -s "$APP_PATH/Contents/Resources/THIRD_PARTY_NOTICES.md"
test -s "$APP_PATH/Contents/Resources/ThirdPartyLicenses/LGPL-2.1-or-later.txt"
test -s "$APP_PATH/Contents/Resources/ThirdPartyLicenses/Sparkle.txt"

SPARKLE_FMWK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
test -x "$SPARKLE_FMWK/Versions/B/Sparkle"
test -L "$SPARKLE_FMWK/Sparkle" # symlink layout survived the copy

plutil -lint "$APP_PLIST" "$SAVER_PLIST"

# Sparkle wiring: feed URL points at this repo, the public key is a real
# ed25519 key (44-char base64, catches shipping the placeholder), and the
# binary resolves the framework inside the bundle only. Explicit exits:
# macOS's bash 3.2 does not apply errexit to failing [[ ]] commands.
FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP_PLIST")"
if [[ "$FEED_URL" != "https://github.com/WolffTech/nes-wallpaper/"* ]]; then
    echo "error: SUFeedURL does not point at this repo: $FEED_URL" >&2
    exit 1
fi
ED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP_PLIST")"
if ! [[ "$ED_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    echo "error: SUPublicEDKey is not an ed25519 public key (placeholder" \
        "still in Scripts/Info.plist?): $ED_KEY" >&2
    exit 1
fi
RPATHS="$(otool -l "$APP_PATH/Contents/MacOS/NESWallpaper" \
    | awk '/LC_RPATH/{getline; getline; print $2}')"
if ! grep -qx '@executable_path/../Frameworks' <<<"$RPATHS"; then
    echo "error: NESWallpaper is missing the bundle-relative rpath" >&2
    exit 1
fi
if grep -qE '\.build|artifacts' <<<"$RPATHS"; then
    echo "error: build-machine rpath leaked into NESWallpaper:" >&2
    echo "$RPATHS" >&2
    exit 1
fi

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST")"
SAVER_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SAVER_PLIST")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PLIST")"
SAVER_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SAVER_PLIST")"
test "$APP_VERSION" = "$SAVER_VERSION"
test "$APP_BUILD" = "$SAVER_BUILD"

for executable in \
    "$APP_PATH/Contents/MacOS/NESWallpaper" \
    "$APP_PATH/Contents/MacOS/nes-helper" \
    "$SAVER_PATH/Contents/MacOS/NESWallpaperSaver"; do
    file "$executable" | grep -q 'arm64'
done

codesign --verify --strict --verbose=2 "$APP_PATH/Contents/MacOS/nes-helper"
codesign --verify --strict --verbose=2 "$SAVER_PATH"
codesign --verify --strict --verbose=2 "$SPARKLE_FMWK"
codesign --verify --strict --deep --verbose=2 "$APP_PATH"
