#!/bin/bash
# Assembles a distributable "NES Wallpaper.app" bundle from the SwiftPM
# release products. Safe to run from any cwd.
#
# APP_VERSION overrides CFBundleShortVersionString in both bundles.
# BUILD_NUMBER overrides CFBundleVersion in both bundles.
# CODESIGN_IDENTITY selects the signing identity (default "-", ad hoc).
# A real identity, e.g. "Developer ID Application: Name (TEAMID)", also
# enables the hardened runtime and a secure timestamp, as notarization
# requires. See Scripts/notarize.sh for the full distribution flow.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

APP_NAME="NES Wallpaper"
DIST_DIR="$REPO_ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
ICNS="$REPO_ROOT/Assets/AppIcon.icns"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
APP_VERSION="${APP_VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"

if [[ -n "$APP_VERSION" && ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
    echo "error: APP_VERSION must be a semantic version (received: $APP_VERSION)" >&2
    exit 1
fi
if [[ -n "$BUILD_NUMBER" && ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: BUILD_NUMBER must be a positive integer (received: $BUILD_NUMBER)" >&2
    exit 1
fi

echo "==> Building (release)"
swift build --package-path "$REPO_ROOT" -c release

# The build dir config is nonstandard; ask SwiftPM where products landed.
BIN_PATH="$(swift build --package-path "$REPO_ROOT" -c release --show-bin-path)"

MAIN_BIN="$BIN_PATH/nes-wallpaper"
HELPER_BIN="$BIN_PATH/nes-helper"
SAVER_DYLIB="$BIN_PATH/libNESWallpaperSaver.dylib"
for bin in "$MAIN_BIN" "$HELPER_BIN" "$SAVER_DYLIB"; do
    if [[ ! -e "$bin" ]]; then
        echo "error: expected product not found: $bin" >&2
        exit 1
    fi
done

echo "==> Assembling $APP_DIR"
# Fresh bundle each run; never touch anything else in dist/.
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"

# nes-wallpaper is renamed to the bundle executable name; nes-helper keeps
# its name because findHelper() looks for "nes-helper" next to the executable.
cp "$MAIN_BIN" "$APP_DIR/Contents/MacOS/NESWallpaper"
cp "$HELPER_BIN" "$APP_DIR/Contents/MacOS/nes-helper"
cp "$SCRIPT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

APP_PLIST="$APP_DIR/Contents/Info.plist"
if [[ -n "$APP_VERSION" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP_PLIST"
fi
if [[ -n "$BUILD_NUMBER" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_PLIST"
fi

if [[ ! -f "$ICNS" ]]; then
    "$SCRIPT_DIR/make-icon.sh"
fi
mkdir -p "$APP_DIR/Contents/Resources"
cp "$ICNS" "$APP_DIR/Contents/Resources/AppIcon.icns"

# Screensaver plugin: the SwiftPM dylib wrapped in the .saver bundle
# structure legacyScreenSaver expects. Shipped inside the app's Resources;
# the app installs it into ~/Library/Screen Savers from Settings.
SAVER_DIR="$APP_DIR/Contents/Resources/$APP_NAME.saver"
echo "==> Assembling $SAVER_DIR"
mkdir -p "$SAVER_DIR/Contents/MacOS"
cp "$SAVER_DYLIB" "$SAVER_DIR/Contents/MacOS/NESWallpaperSaver"
cp "$SCRIPT_DIR/Saver-Info.plist" "$SAVER_DIR/Contents/Info.plist"

SAVER_PLIST="$SAVER_DIR/Contents/Info.plist"
if [[ -n "$APP_VERSION" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$SAVER_PLIST"
fi
if [[ -n "$BUILD_NUMBER" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$SAVER_PLIST"
fi

if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
    echo "==> Codesigning (ad hoc)"
    SIGN_FLAGS=(--timestamp=none)
else
    echo "==> Codesigning ($CODESIGN_IDENTITY)"
    SIGN_FLAGS=(--options runtime --timestamp)
fi
# Sign nested code first (helper binary, saver bundle), then the app.
codesign --force --sign "$CODESIGN_IDENTITY" "${SIGN_FLAGS[@]}" "$APP_DIR/Contents/MacOS/nes-helper"
codesign --force --sign "$CODESIGN_IDENTITY" "${SIGN_FLAGS[@]}" "$SAVER_DIR"
codesign --force --sign "$CODESIGN_IDENTITY" "${SIGN_FLAGS[@]}" "$APP_DIR"

echo "==> Done: $APP_DIR"
codesign -dv "$APP_DIR"
