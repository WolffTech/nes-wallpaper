#!/bin/bash
# SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
# SPDX-License-Identifier: GPL-2.0-only

# Compiles the native Icon Composer document into the resources used by the
# app bundle: Assets.car for adaptive Liquid Glass rendering and AppIcon.icns
# as the fallback for older supported macOS releases. It also exports a
# flattened 1024px PNG for documentation and other uses. Safe to run from any
# cwd.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

SOURCE="$REPO_ROOT/Assets/AppIcon.icon"
ICNS="$REPO_ROOT/Assets/AppIcon.icns"
ASSET_CAR="$REPO_ROOT/Assets/AppIconAssets.car"
PNG="$REPO_ROOT/Assets/AppIcon.png"

if [[ ! -d "$SOURCE" ]]; then
    echo "error: Icon Composer document not found: $SOURCE" >&2
    exit 1
fi

ACTOOL_PATH=""
if ACTOOL_PATH="$(xcrun --find actool 2>/dev/null)"; then
    :
elif [[ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/actool" ]]; then
    ACTOOL_PATH="/Applications/Xcode.app/Contents/Developer/usr/bin/actool"
elif [[ -x "/Applications/Xcode-beta.app/Contents/Developer/usr/bin/actool" ]]; then
    ACTOOL_PATH="/Applications/Xcode-beta.app/Contents/Developer/usr/bin/actool"
else
    echo "error: actool not found; install the current Xcode release" >&2
    exit 1
fi

COMPILE_DIR="$(mktemp -d)"
PARTIAL_PLIST="$COMPILE_DIR/AppIcon-Info.plist"
trap 'rm -rf "$COMPILE_DIR"' EXIT

echo "==> Compiling $(basename "$SOURCE")"
"$ACTOOL_PATH" \
    --compile "$COMPILE_DIR" \
    --output-format human-readable-text \
    --warnings \
    --notices \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --target-device mac \
    --standalone-icon-behavior all \
    --app-icon AppIcon \
    --output-partial-info-plist "$PARTIAL_PLIST" \
    "$SOURCE"

cp "$COMPILE_DIR/AppIcon.icns" "$ICNS"
cp "$COMPILE_DIR/Assets.car" "$ASSET_CAR"
iconutil -c iconset "$COMPILE_DIR/AppIcon.icns" -o "$COMPILE_DIR/AppIcon.iconset"
cp "$COMPILE_DIR/AppIcon.iconset/icon_512x512@2x.png" "$PNG"
echo "==> Done"
