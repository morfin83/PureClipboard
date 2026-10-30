#!/bin/zsh
# Prepares the installer disk image: Pure Clipboard.app + a link to /Applications ("drag the app onto Applications").
# NOTHING is created unless you pass --create. Without it the script only prints what it would do.
#
#   scripts/make-dmg.sh            plan only
#   scripts/make-dmg.sh --create   builds dist/PureClipboard-<version>-<archs>.dmg and its .sha256 (not published anywhere)
#
# Uses build/PureClipboard.app (run scripts/build-app.sh first). Nothing is uploaded, tagged or released.
set -euo pipefail

ROOT="${0:A:h:h}"
APP="${APP:-$ROOT/build/PureClipboard.app}"
DIST="${DIST_DIR:-$ROOT/dist}"
CREATE=0
[[ "${1:-}" == "--create" ]] && CREATE=1

[[ -d "$APP" ]] || { echo "Chybí $APP – nejdřív spusťte scripts/build-app.sh" >&2; exit 2; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/PureClipboard" | tr ' ' '-')"
SIGNATURE="$(codesign -dv "$APP" 2>&1 | sed -n 's/^Signature=//p' | head -1)"
NAME="PureClipboard-$VERSION-$ARCHS"
DMG="$DIST/$NAME.dmg"

echo "Aplikace:     $APP (verze $VERSION, architektura $ARCHS)"
echo "Podpis:       ${SIGNATURE:-Developer ID / jiný než ad-hoc}"
echo "Výstup:       $DMG"
echo "Kontr. součet: $DMG.sha256 (SHA-256)"
echo "Obsah obrazu: Pure Clipboard.app, odkaz Applications, PŘEČTĚTE.txt"
if [[ "$SIGNATURE" == "adhoc" ]]; then
  echo "POZOR: aplikace je podepsaná jen ad-hoc a není notarizovaná. macOS (Gatekeeper) ji při prvním spuštění zablokuje;"
  echo "       postup povolení je v docs/INSTALACE.md. Ad-hoc podpis notarizaci nenahrazuje."
fi

if (( ! CREATE )); then
  echo
  echo "Plán – nic nebylo vytvořeno. Pro vytvoření spusťte: scripts/make-dmg.sh --create"
  exit 0
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$DIST"
ditto "$APP" "$STAGE/Pure Clipboard.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/PŘEČTĚTE.txt" <<TXT
Pure Clipboard $VERSION

1. Přetáhněte „Pure Clipboard“ na složku „Applications“.
2. Aplikaci spusťte z Applications (ne přímo z tohoto obrazu).
3. Aplikace není notarizovaná Applem. Pokud ji macOS zablokuje, postup je v docs/INSTALACE.md
   (Nastavení systému → Soukromí a zabezpečení → „Přesto otevřít“).
Ověření souboru: shasum -a 256 -c PureClipboard-$VERSION-$ARCHS.dmg.sha256
TXT

rm -f "$DMG" "$DMG.sha256"
hdiutil create -volname "Pure Clipboard" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
IDENTITY="${CODESIGN_IDENTITY:--}"
if [[ "$IDENTITY" != "-" ]]; then
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
fi
( cd "$DIST" && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256" )
hdiutil verify "$DMG" >/dev/null
echo
echo "Vytvořeno: $DMG ($(du -h "$DMG" | cut -f1))"
echo "SHA-256:   $(cut -d' ' -f1 "$DMG.sha256")"
echo "Nic nebylo nahráno ani publikováno."
