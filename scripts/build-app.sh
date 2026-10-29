#!/bin/zsh
# Builds build/PureClipboard.app from the Swift package. No installation, no admin rights.
set -euo pipefail

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
ROOT="${0:A:h:h}"
APP="$ROOT/build/PureClipboard.app"

cd "$ROOT"
swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
BIN="$BIN_DIR/PureClipboard"
HELPER="$BIN_DIR/pureclipboard-hook"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PureClipboard"
cp "$HELPER" "$APP/Contents/MacOS/pureclipboard-hook"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# The bundle version and the helper's embedded version must agree.
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
HELPER_VERSION="$("$APP/Contents/MacOS/pureclipboard-hook" version)"
[[ "$PLIST_VERSION" == "$HELPER_VERSION" ]] || { echo "Version mismatch: Info.plist $PLIST_VERSION vs helper $HELPER_VERSION" >&2; exit 1; }

codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/pureclipboard-hook" >/dev/null
codesign --force --sign - --timestamp=none "$APP" >/dev/null
codesign --verify --strict "$APP"

echo "$APP"
