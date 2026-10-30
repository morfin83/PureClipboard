#!/bin/zsh
# Builds PureClipboard.app from the Swift package. No installation, no admin rights.
#
#   scripts/build-app.sh                         ad-hoc signed, Apple Silicon only (default)
#   ARCHS="arm64 x86_64" scripts/build-app.sh    universal build (Intel slice is only compiled, not verified)
#   CODESIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#                                                Developer ID signature with hardened runtime and secure timestamp
#                                                (the first step towards notarization; see scripts/notarize.sh)
#   OUT_DIR=/some/dir scripts/build-app.sh       build somewhere other than ./build
set -euo pipefail

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
ROOT="${0:A:h:h}"
OUT_DIR="${OUT_DIR:-$ROOT/build}"
APP="$OUT_DIR/PureClipboard.app"
ARCHS="${ARCHS:-arm64}"
IDENTITY="${CODESIGN_IDENTITY:--}"

ARCH_FLAGS=()
for arch in ${=ARCHS}; do ARCH_FLAGS+=(--arch "$arch"); done

cd "$ROOT"
swift build -c release "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PureClipboard" "$APP/Contents/MacOS/PureClipboard"
cp "$BIN_DIR/pureclipboard-hook" "$APP/Contents/MacOS/pureclipboard-hook"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# The bundle version and the helper's embedded version must agree.
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
HELPER_VERSION="$("$APP/Contents/MacOS/pureclipboard-hook" version)"
[[ "$PLIST_VERSION" == "$HELPER_VERSION" ]] || { echo "Version mismatch: Info.plist $PLIST_VERSION vs helper $HELPER_VERSION" >&2; exit 1; }

SIGN_FLAGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" == "-" ]]; then
  SIGN_FLAGS+=(--timestamp=none)            # ad-hoc: works offline, does NOT replace notarization
else
  SIGN_FLAGS+=(--options runtime --timestamp)   # Developer ID: hardened runtime + secure timestamp (needs network)
fi
# Inner executable first, then the bundle.
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/pureclipboard-hook" >/dev/null
codesign "${SIGN_FLAGS[@]}" "$APP" >/dev/null
codesign --verify --strict --deep "$APP"

echo "App:        $APP"
echo "Version:    $PLIST_VERSION ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist"))"
echo "Archs:      $(lipo -archs "$APP/Contents/MacOS/PureClipboard")"
echo "Signature:  $(codesign -dv "$APP" 2>&1 | sed -n 's/^Signature=//p;s/^Authority=//p' | head -1) (identity: $IDENTITY)"
