#!/bin/bash
# Assembles a distributable "NES Wallpaper.app" bundle from the SwiftPM
# release products. Safe to run from any cwd.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

APP_NAME="NES Wallpaper"
DIST_DIR="$REPO_ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"

echo "==> Building (release)"
swift build --package-path "$REPO_ROOT" -c release

# The build dir config is nonstandard; ask SwiftPM where products landed.
BIN_PATH="$(swift build --package-path "$REPO_ROOT" -c release --show-bin-path)"

MAIN_BIN="$BIN_PATH/nes-wallpaper"
HELPER_BIN="$BIN_PATH/nes-helper"
for bin in "$MAIN_BIN" "$HELPER_BIN"; do
    if [[ ! -x "$bin" ]]; then
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

echo "==> Codesigning (ad hoc)"
# Sign the nested helper explicitly first (standalone binary), then the app.
codesign --force --sign - --timestamp=none "$APP_DIR/Contents/MacOS/nes-helper"
codesign --force --sign - --timestamp=none "$APP_DIR"

echo "==> Done: $APP_DIR"
codesign -dv "$APP_DIR"
