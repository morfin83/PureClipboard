#!/bin/zsh
# Notarization of a Developer ID signed DMG (NOT possible with the ad-hoc signature of the default build).
#
#   scripts/notarize.sh dist/PureClipboard-<v>-arm64.dmg            plan only (prints the commands)
#   NOTARY_PROFILE=<keychain-profile> scripts/notarize.sh <dmg> --submit
#
# Prerequisites (paid Apple Developer Program): a "Developer ID Application" certificate, the app and the DMG signed with it
# (CODESIGN_IDENTITY=… scripts/build-app.sh && scripts/make-dmg.sh --create), and a notarytool keychain profile created once with:
#   xcrun notarytool store-credentials <profile> --apple-id … --team-id …   (the password is entered in the prompt, never in this repo)
# This script has NOT been run against Apple's service yet: no certificate or profile exists on this machine.
set -euo pipefail

DMG="${1:-}"
SUBMIT=0
[[ "${2:-}" == "--submit" ]] && SUBMIT=1
[[ -n "$DMG" && -f "$DMG" ]] || { echo "Použití: scripts/notarize.sh <soubor.dmg> [--submit]" >&2; exit 2; }

signature="$(codesign -dv "$DMG" 2>&1 || true)"
if ! grep -q "Authority=Developer ID Application" <<< "$signature"; then
  echo "Odmítnuto: DMG není podepsán certifikátem „Developer ID Application“ (ad-hoc podpis notarizovat nelze)." >&2
  echo "Postup: CODESIGN_IDENTITY=\"Developer ID Application: …\" scripts/build-app.sh && scripts/make-dmg.sh --create" >&2
  (( SUBMIT )) && exit 3
fi

echo "1. xcrun notarytool submit \"$DMG\" --keychain-profile \"\${NOTARY_PROFILE}\" --wait"
echo "2. xcrun stapler staple \"$DMG\""
echo "3. xcrun stapler validate \"$DMG\""
echo "4. spctl -a -t open --context context:primary-signature -vv \"$DMG\""
echo "5. shasum -a 256 \"$DMG\" > \"$DMG.sha256\"   (po staplování se SHA-256 počítá znovu)"
if (( ! SUBMIT )); then
  echo; echo "Plán – nic nebylo odesláno. Pro odeslání: NOTARY_PROFILE=<profil> scripts/notarize.sh \"$DMG\" --submit"
  exit 0
fi
[[ -n "${NOTARY_PROFILE:-}" ]] || { echo "Chybí NOTARY_PROFILE (profil z notarytool store-credentials)." >&2; exit 2; }

xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG"
# Stapling changed the bytes of the DMG, so the checksum is recomputed and the old one is replaced.
( cd "${DMG:h}" && shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256" )
echo "Nový SHA-256 po staplování: $(cut -d' ' -f1 "$DMG.sha256")  (zveřejněte tento, ne předchozí)"
