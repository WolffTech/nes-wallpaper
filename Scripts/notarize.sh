#!/bin/bash
# Builds a Developer ID-signed bundle, notarizes it with Apple, staples the
# ticket, and produces a distributable zip in dist/. Safe to run from any cwd.
#
# One-time setup:
#   1. A "Developer ID Application" certificate in the keychain
#      (Xcode -> Settings -> Accounts -> Manage Certificates).
#   2. xcrun notarytool store-credentials nes-wallpaper \
#          --apple-id <apple-id> --team-id <team-id> --password <app-specific>
#
# Environment:
#   CODESIGN_IDENTITY  signing identity; defaults to the first Developer ID
#                      Application certificate found in the keychain.
#   NOTARY_PROFILE     notarytool keychain profile name (default: nes-wallpaper)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

APP_DIR="$REPO_ROOT/dist/NES Wallpaper.app"
NOTARY_PROFILE="${NOTARY_PROFILE:-nes-wallpaper}"

if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    CODESIGN_IDENTITY="$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
    if [[ -z "$CODESIGN_IDENTITY" ]]; then
        echo "error: no Developer ID Application certificate in the keychain." >&2
        echo "Create one via Xcode -> Settings -> Accounts -> Manage Certificates." >&2
        exit 1
    fi
fi

CODESIGN_IDENTITY="$CODESIGN_IDENTITY" "$SCRIPT_DIR/make-app.sh"

echo "==> Verifying signature"
codesign --verify --strict --deep "$APP_DIR"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
ZIP="$REPO_ROOT/dist/NES-Wallpaper-$VERSION.zip"

echo "==> Submitting for notarization (profile: $NOTARY_PROFILE)"
SUBMIT_ZIP="$(mktemp -d)/NES-Wallpaper-notarize.zip"
trap 'rm -rf "$(dirname "$SUBMIT_ZIP")"' EXIT
ditto -c -k --keepParent "$APP_DIR" "$SUBMIT_ZIP"

SUBMIT_OUTPUT="$(xcrun notarytool submit "$SUBMIT_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
echo "$SUBMIT_OUTPUT"
if ! grep -q 'status: Accepted' <<<"$SUBMIT_OUTPUT"; then
    echo "error: notarization not accepted; fetching the log:" >&2
    SUBMISSION_ID="$(sed -n 's/^ *id: //p' <<<"$SUBMIT_OUTPUT" | head -1)"
    if [[ -n "$SUBMISSION_ID" ]]; then
        xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2
    fi
    exit 1
fi

echo "==> Stapling ticket"
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"

echo "==> Creating distribution zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP_DIR" "$ZIP"

echo "==> Done"
echo "    App: $APP_DIR"
echo "    Zip: $ZIP"
spctl -a -vv "$APP_DIR"
