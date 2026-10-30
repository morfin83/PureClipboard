#!/bin/zsh
# Prepares the installer disk image: Pure Clipboard.app + a link to /Applications ("drag the app onto Applications").
# NOTHING is created unless you pass --create. Without it the script only prints what it would do.
#
#   scripts/make-dmg.sh            plan only
#   scripts/make-dmg.sh --create   builds dist/PureClipboard-<version>-<archs>[-adhoc-TEST].dmg and its .sha256
#
# Uses build/PureClipboard.app (run scripts/build-app.sh first). Nothing is uploaded, tagged or released.
# An ad-hoc signed app yields a clearly labelled TEST image (file name, volume name, background, README); a Developer ID
# signed app yields the regular image, with no "not notarized" text (notarize afterwards with scripts/notarize.sh,
# which recomputes the SHA-256 because stapling changes the bytes).
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
ADHOC=0
[[ "$SIGNATURE" == "adhoc" ]] && ADHOC=1
if (( ADHOC )); then
  NAME="PureClipboard-$VERSION-$ARCHS-adhoc-TEST"
  VOLNAME="Pure Clipboard (TEST ad-hoc)"
  NOTE="Testovací sestavení · podepsáno ad-hoc · není notarizované"
else
  NAME="PureClipboard-$VERSION-$ARCHS"
  VOLNAME="Pure Clipboard"
  NOTE=""
fi
DMG="$DIST/$NAME.dmg"

echo "Aplikace:     $APP (verze $VERSION, architektura $ARCHS)"
echo "Podpis:       ${SIGNATURE:-Developer ID / jiný než ad-hoc}"
echo "Výstup:       $DMG"
echo "Kontr. součet: $DMG.sha256 (SHA-256)"
echo "Obsah obrazu: Pure Clipboard.app, odkaz Applications, PŘEČTĚTE.txt, pozadí ve stylu PURE"
if (( ADHOC )); then
  echo "POZOR: aplikace je podepsaná jen ad-hoc a není notarizovaná. Obraz je označen jako TESTOVACÍ a nesmí se publikovat"
  echo "       jako oficiální stažení ani GitHub Release. macOS (Gatekeeper) ji při prvním spuštění zablokuje (docs/INSTALACE.md)."
fi

if (( ! CREATE )); then
  echo
  echo "Plán – nic nebylo vytvořeno. Pro vytvoření spusťte: scripts/make-dmg.sh --create"
  exit 0
fi

STAGE="$(mktemp -d)"
RW="$(mktemp -d)/rw.dmg"
trap 'rm -rf "$STAGE" "${RW:h}"; [[ -n "${MNT:-}" ]] && hdiutil detach "$MNT" -quiet 2>/dev/null || true' EXIT
mkdir -p "$DIST" "$STAGE/.background"
ditto "$APP" "$STAGE/Pure Clipboard.app"
ln -s /Applications "$STAGE/Applications"
swift "$ROOT/scripts/make-dmg-background.swift" "$STAGE/.background/background.png" "Přetáhněte Pure Clipboard do složky Applications" "$NOTE" >/dev/null
if (( ADHOC )); then
  cat > "$STAGE/PŘEČTĚTE.txt" <<TXT
Pure Clipboard $VERSION – TESTOVACÍ SESTAVENÍ (ad-hoc podpis)

Tento obraz není oficiální vydání. Aplikace je podepsaná jen ad-hoc a NENÍ notarizovaná Applem,
proto ji macOS při prvním spuštění zablokuje.

1. Přetáhněte „Pure Clipboard“ na složku „Applications“.
2. Aplikaci spusťte z Applications (ne přímo z tohoto obrazu).
3. Pokud ji macOS zablokuje: Nastavení systému → Soukromí a zabezpečení → „Přesto otevřít“.
Podrobně: docs/INSTALACE.md v repozitáři.
Ověření souboru: shasum -a 256 -c $NAME.dmg.sha256
TXT
else
  cat > "$STAGE/PŘEČTĚTE.txt" <<TXT
Pure Clipboard $VERSION

1. Přetáhněte „Pure Clipboard“ na složku „Applications“.
2. Aplikaci spusťte z Applications (ne přímo z tohoto obrazu).
Ověření souboru: shasum -a 256 -c $NAME.dmg.sha256
TXT
fi

hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ "$RW" >/dev/null
MNT="$(hdiutil attach "$RW" -nobrowse -noverify -noautoopen | awk -F'\t' '/\/Volumes\//{print $NF}' | head -1)"
# Window layout through Finder; if automation is not allowed the image is still valid, just with default layout.
if ! osascript <<OSA >/dev/null 2>&1
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 96
    set background picture of opts to file ".background:background.png"
    set position of item "Pure Clipboard.app" of container window to {170, 185}
    set position of item "Applications" of container window to {490, 185}
    set position of item "PŘEČTĚTE.txt" of container window to {330, 330}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
OSA
then
  echo "Poznámka: Finder rozložení okna nepovolil; obraz je platný, ale bez nastaveného rozložení."
fi
sync
hdiutil detach "$MNT" -quiet; MNT=""
rm -f "$DMG" "$DMG.sha256"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
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
