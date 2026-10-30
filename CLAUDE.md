# Pure Clipboard — pravidla pro Claude

Nativní macOS aplikace (Swift, MIT). Zdroje: `Sources/`, testy `Tests/`, skripty `scripts/`, dokumentace `docs/`.

## Build a testy
- Testy: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` (247 testů).
- Sestavení: `OUT_DIR=<složka> zsh scripts/build-app.sh` (ad-hoc, arm64).
- DMG: `APP=<app> DIST_DIR=<složka> zsh scripts/make-dmg.sh --create` (ad-hoc = označený TESTOVACÍ DMG).
- Notarizace (`scripts/notarize.sh`) jen s Developer ID a výslovným souhlasem; vyřazeno, dokud vlastník neřekne jinak.

## Vydání
- Verze se musí shodovat v `Resources/Info.plist` a `Sources/PureClipboardCore/StopHookHandler.swift`.
- Testovací DMG se nesmí publikovat jako oficiální stažení. Pre-release na GitHubu jen s označením testovací verze a po schválení.

## Soukromí a bezpečnost
- Historie schránky je ve výchozím stavu vypnutá. Telefonní přenos (Termux, adb) běží jen na výslovný příkaz.
- Neměň SSH, `authorized_keys` ani Tailscale bez potvrzení v aplikaci.

## Komunikace a stavy
- S uživatelem komunikuj česky, pokud nepíše jiným jazykem. Texty pro uživatele zachovávej v jazyce webu (cs/en).
- Označuj stav: OVĚŘENO, PROVEDENO, NEOVĚŘENO, NAVRŽENO, VYŽADUJE SCHVÁLENÍ. Nic neoznačuj jako hotové bez ověření.

## Schvalování (bez výslovného souhlasu NEDĚLAT)
- push na `main`, vydání (release, tag, DMG pro veřejnost), nasazení na produkci, změna viditelnosti repozitáře
- publikace osobních údajů, zdrojů nebo binárních souborů, které nejsou určené k veřejnému zveřejnění
- mazání nebo přepisování historie (force push, reset sdílených větví)
- placené kroky, stahování velkých obrazů, vytváření virtuálních strojů

## Bezpečnost a soukromí
- Nikdy necommituj tajemství: klíče, tokeny, hesla, certifikáty, osobní údaje, soukromé exporty chatů, obnovovací důkazy.
- Binární distribuční soubory (DMG, ZIP, média větší než běžné assety) do Gitu nepatří. Jsou v `.gitignore`.
- Před každým commitem zkontroluj `git status` a `git diff --cached`.

## Git
- Práce na větvi, ne přímo na `main`. Commit zprávy končí řádkem `Co-Authored-By: Claude Haiku 5.5 <noreply@anthropic.com>`.
- Záznam změn a nasazení patří do `RELEASES.md` (pokud repo má), záznam stavu do dokumentace projektu.

## Hlášení chyb
- Hlášení od uživatelů se čtou z GitHub Issues (automatizace v Claude Desktopu). Odpovědi na hlášení řídí pravidla v `~/Documents/PURE-bugs/`.
