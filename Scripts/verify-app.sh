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

plutil -lint "$APP_PLIST" "$SAVER_PLIST"

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
codesign --verify --strict --deep --verbose=2 "$APP_PATH"
