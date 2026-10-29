#!/bin/zsh
# Builds build/PureClipboard.app from the Swift package. No installation, no admin rights.
set -euo pipefail

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
ROOT="${0:A:h:h}"
APP="$ROOT/build/PureClipboard.app"

cd "$ROOT"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/PureClipboard"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PureClipboard"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$APP" >/dev/null

echo "$APP"
