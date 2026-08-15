#!/bin/bash
# SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
# SPDX-License-Identifier: GPL-2.0-only

# Runs the deterministic nestest ROM and validates the final rendered frame.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
swift build --package-path "$REPO_ROOT" -c release --product nes-headless
BIN_PATH="$(swift build --package-path "$REPO_ROOT" -c release --show-bin-path)"
FRAME_DIR="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/nes-wallpaper-frames.XXXXXX")"
trap 'rm -rf "$FRAME_DIR"' EXIT

"$BIN_PATH/nes-headless" \
    "$REPO_ROOT/TestData/nestest.nes" \
    --frames 60 \
    --dump-every 60 \
    --out "$FRAME_DIR" \
    --raw

FRAME="$FRAME_DIR/frame_000059.png"
test -s "$FRAME"
test "$(sips -g pixelWidth "$FRAME" | awk '/pixelWidth/ { print $2 }')" = 256
test "$(sips -g pixelHeight "$FRAME" | awk '/pixelHeight/ { print $2 }')" = 240
# Hash the raw framebuffer, not the PNG: ImageIO's encoded bytes can change
# across macOS releases even when the pixels are identical.
echo "9fc9dd1aea285bbfa58dafc6d02996ce890216fd779bdec13858519352a8cd87  $FRAME_DIR/frame_000059.raw" \
    | shasum -a 256 --check
