# Distribuce Pure Clipboard – postup pro vydavatele

Stav (v0.7.0): **lokální testovací ad-hoc DMG existuje** (`dist/PureClipboard-0.7.0-arm64-adhoc-TEST.dmg`, ignorováno Gitem), **nic nebylo vydáno ani publikováno** a nevznikl GitHub Release. Podepsané a notarizované DMG **zbývá** a vyžaduje placený Apple Developer Program. Skripty bez `--create` / `--submit` jen vypíšou plán.

Plnění závazných požadavků najdete v [PLAN.md](../PLAN.md).

## Přehled souborů

| Soubor | K čemu |
|---|---|
| `scripts/build-app.sh` | sestaví `build/PureClipboard.app` (výchozí: arm64, ad-hoc podpis) |
| `scripts/make-dmg.sh` | DMG s pozadím PURE, odkazem na Applications, návodem a SHA-256 (jen s `--create`); ad-hoc app → název `…-adhoc-TEST`, popisky „testovací“; Developer ID app → běžný název bez textu o nenotarizaci |
| `scripts/make-dmg-background.swift` | pozadí okna DMG |
| `scripts/notarize.sh` | notarizace DMG podepsaného Developer ID (jen s `--submit`) |
| `scripts/make-icon-from-artwork.swift` | z dodané grafiky `Resources/Artwork/AppIcon-source.png` vyrobí `.iconset` (`iconutil -c icns` ho převede na `Resources/AppIcon.icns`) |
| `scripts/make-icon.swift` | původní procedurální ikona, záloha |
| `Resources/Info.plist` | identita, verze, kategorie, ikona |
| `docs/INSTALACE.md` | návod pro uživatele |
| `docs/WEB-PURESTUDIO.md` | texty pro webovou stránku |

## Identita a verzování

- **Bundle identifier:** `studio.pure.clipboard`: stabilní, nikdy se nemění (váže se na něj Gatekeeper, uživatelská data i budoucí aktualizace).
- **`CFBundleShortVersionString`:** sémantická verze `MAJOR.MINOR.PATCH`. Musí se rovnat `PureClipboardVersion.string` v kódu (pomocný program ji vypisuje). `build-app.sh` sestavení zastaví, pokud se liší.
- **`CFBundleVersion`:** celé číslo, které se **při každém vydání zvyšuje** (nikdy neklesá).
- Při zvýšení verze změňte oba soubory (`Resources/Info.plist`, `Sources/PureClipboardCore/StopHookHandler.swift`). Test `ReleaseMetadataTests` kontroluje shodu.

## Podpis a notarizace

### Dnes: ad-hoc (bez placeného účtu)
`scripts/build-app.sh` podepisuje `codesign --sign -`. Ad-hoc podpis chrání celistvost balíčku, **nedokazuje identitu vydavatele a nenahrazuje notarizaci**. Gatekeeper takovou aplikaci při prvním spuštění zablokuje; uživatel ji musí povolit ručně (`docs/INSTALACE.md`). Nikdy netvrďte, že je aplikace „ověřená Applem“.

### Zbývající krok: Developer ID, hardened runtime, notarizace, stapling (vyžaduje placený účet)
Přesný postup (jednou: certifikát „Developer ID Application“ v klíčence a `xcrun notarytool store-credentials pure-clipboard --apple-id … --team-id …`):
1. `CODESIGN_IDENTITY="Developer ID Application: Jméno (TEAMID)" scripts/build-app.sh` – hardened runtime + časové razítko.
2. `CODESIGN_IDENTITY="…" scripts/make-dmg.sh --create` – běžný název bez „TEST“.
3. `NOTARY_PROFILE=pure-clipboard scripts/notarize.sh dist/PureClipboard-<v>-arm64.dmg --submit` – odeslání, čekání, `stapler staple`, `stapler validate`, `spctl` a **nový výpočet SHA-256** (soubor `.sha256` se přepíše).
4. Ověření Gatekeeperem: `spctl -a -t open --context context:primary-signature -vv <dmg>` a po instalaci `spctl -a -vv "/Applications/Pure Clipboard.app"`.
5. Zveřejnit **až** konečný SHA-256 (po staplování) vedle odkazu a aktivovat tlačítko na webu (`web/pure-clipboard/HANDOFF-CODEX.md`).
Tento postup **nebyl proti Apple spuštěn**.

### Podrobnosti Developer ID
Vyžaduje placený Apple Developer Program.

```bash
CODESIGN_IDENTITY="Developer ID Application: Jméno (TEAMID)" scripts/build-app.sh   # hardened runtime + časové razítko
CODESIGN_IDENTITY="Developer ID Application: Jméno (TEAMID)" scripts/make-dmg.sh --create
xcrun notarytool store-credentials pure-clipboard --apple-id … --team-id …           # jednou; heslo se zadává v promptu
NOTARY_PROFILE=pure-clipboard scripts/notarize.sh dist/PureClipboard-<v>-arm64.dmg --submit
```

- Hardened runtime nevyžaduje pro tuto aplikaci žádné speciální entitlements (nepoužívá JIT, nepřistupuje k jiným procesům, není v sandboxu).
- `notarize.sh` ad-hoc podepsaný soubor **odmítne** (návratový kód 3).
- **Neověřeno:** skripty pro Developer ID a notarizaci nebyly spuštěny proti službě Apple, protože na tomto počítači není certifikát ani profil. První ostré nasazení počítejte s drobnými úpravami.
- Po notarizaci se změní bajty DMG, takže se **SHA-256 počítá znovu** a zveřejňuje až nový.

## Kontrolní součet
`make-dmg.sh --create` vedle DMG zapíše `…dmg.sha256` ve formátu `shasum` (`hash  soubor`), takže uživatel může použít `shasum -a 256 -c soubor.dmg.sha256`. Hodnotu uveďte u odkazu ke stažení.

## Architektury

- **Primární: Apple Silicon (arm64).**
- `ARCHS="arm64 x86_64" scripts/build-app.sh` sestaví univerzální binárku a x86_64 část pomocného programu běží pod Rosettou. Je to **jen** kontrola sestavení: neověřuje chování na skutečném Intelu (ani aplikaci s GUI, schránkou a integracemi). Xcode navíc upozorňuje, že x86_64 je pro cílový systém zastaralé.
- **Intel proto nelze označit za podporovaný**, dokud se neotestuje na Intel Macu (`swift test`, `scripts/integration-test.sh`, ruční průchod GUI).
- Minimální systém je v plistu `14.0`, ale vyzkoušeno bylo jen na macOS 27. Starší verze před vydáním ověřte.

## Aktualizace

Aplikace je **připravená**, ale mechanismus ještě není: stabilní bundle ID, rostoucí `CFBundleVersion`, pomocný program, který aplikace pozná jako „starší“ a nabídne **Aktualizovat**, a hooky, jejichž příkaz se při aktualizaci nemění (schválení v Codexu přetrvá).

Doporučený další krok (po Developer ID): [Sparkle](https://sparkle-project.org) s podepsaným `appcast.xml` (EdDSA klíč uložený mimo repozitář). Aplikace dnes **nemá žádný síťový kód**, jeho přidání je změna soukromí, kterou je nutné uvést na webu i v návodu. Do té doby se aktualizuje ručně (nová verze přes starou).

## Kontrolní seznam před vydáním (až na pokyn)

1. `swift test` a `scripts/integration-test.sh` zelené; verze v plistu a v kódu stejné a zvýšené.
2. `scripts/build-app.sh` (případně s `CODESIGN_IDENTITY`), `codesign --verify --strict --deep build/PureClipboard.app`.
3. `scripts/make-dmg.sh --create`; otevřít DMG na čistém účtu a vyzkoušet přetažení do Applications a první spuštění včetně Gatekeeperu.
4. SHA-256 doplnit do `docs/WEB-PURESTUDIO.md` (`{{SHA256}}`, `{{VERZE}}`, `{{KONTAKT}}`).
5. Zkontrolovat texty „Co nepsat“ na konci `docs/WEB-PURESTUDIO.md`.
6. Teprve poté publikovat (mimo repozitář; žádný skript nic nenahrává).
