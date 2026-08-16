#!/bin/bash
# SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
# SPDX-License-Identifier: GPL-2.0-only

# Packages NES Wallpaper.app in a compressed disk image with an Applications
# shortcut. Safe to run from any cwd.
#
# Usage: ./Scripts/make-dmg.sh [app-path] [output-path]
# DMG_VOLUME_NAME overrides the mounted volume name (default: NES Wallpaper).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

if (( $# > 2 )); then
    echo "usage: $0 [app-path] [output-path]" >&2
    exit 2
fi

APP_PATH="${1:-$REPO_ROOT/dist/NES Wallpaper.app}"
if [[ ! -d "$APP_PATH" || "${APP_PATH##*.}" != "app" ]]; then
    echo "error: app bundle not found: $APP_PATH" >&2
    exit 1
fi

if (( $# >= 2 )); then
    DMG_PATH="$2"
else
    APP_VERSION="$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleShortVersionString' \
        "$APP_PATH/Contents/Info.plist")"
    DMG_PATH="$REPO_ROOT/dist/NES-Wallpaper-$APP_VERSION.dmg"
fi

if [[ "$DMG_PATH" != *.dmg ]]; then
    echo "error: output path must end in .dmg: $DMG_PATH" >&2
    exit 1
fi

DMG_VOLUME_NAME="${DMG_VOLUME_NAME:-NES Wallpaper}"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nes-wallpaper-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

echo "==> Staging disk image contents"
ditto "$APP_PATH" "$STAGING_DIR/$(basename "$APP_PATH")"
ln -s /Applications "$STAGING_DIR/Applications"

mkdir -p "$(dirname "$DMG_PATH")"
rm -f "$DMG_PATH"

echo "==> Creating $DMG_PATH"
hdiutil create \
    -volname "$DMG_VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -fs HFS+ \
    -format UDZO \
    "$DMG_PATH"
hdiutil verify "$DMG_PATH"

echo "==> Done: $DMG_PATH"
