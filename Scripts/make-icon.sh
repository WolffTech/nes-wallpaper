#!/bin/bash
# Builds Assets/AppIcon.icns from the source logo. The logo itself is
# read-only input and is never modified. Safe to run from any cwd.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

SOURCE="$REPO_ROOT/Assets/nes-wallpaper-logo-concept.png"
ICNS="$REPO_ROOT/Assets/AppIcon.icns"

if [[ ! -f "$SOURCE" ]]; then
    echo "error: source logo not found: $SOURCE" >&2
    exit 1
fi

ICONSET="$(mktemp -d)/AppIcon.iconset"
trap 'rm -rf "$(dirname "$ICONSET")"' EXIT

echo "==> Rendering iconset from $(basename "$SOURCE")"
swift "$SCRIPT_DIR/make-icon.swift" "$SOURCE" "$ICONSET"

echo "==> Building $ICNS"
iconutil -c icns "$ICONSET" -o "$ICNS"
echo "==> Done"
