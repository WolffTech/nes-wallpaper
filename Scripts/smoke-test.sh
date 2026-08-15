#!/bin/bash
# Runs the deterministic nestest ROM and validates the final rendered frame.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BIN_PATH="$(swift build --package-path "$REPO_ROOT" -c release --show-bin-path)"
FRAME_DIR="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/nes-wallpaper-frames.XXXXXX")"
trap 'rm -rf "$FRAME_DIR"' EXIT

"$BIN_PATH/nes-headless" \
    "$REPO_ROOT/TestData/nestest.nes" \
    --frames 60 \
    --dump-every 60 \
    --out "$FRAME_DIR"

FRAME="$FRAME_DIR/frame_000059.png"
test -s "$FRAME"
test "$(sips -g pixelWidth "$FRAME" | awk '/pixelWidth/ { print $2 }')" = 256
test "$(sips -g pixelHeight "$FRAME" | awk '/pixelHeight/ { print $2 }')" = 240
echo "bcd4b20a2c954e4581eddadc1545d26e2962c81686e71bd930bbf2203acb1940  $FRAME" \
    | shasum -a 256 --check
