# Pure Clipboard – stav projektu

Snímek ze **30. 10. 2026**, verze **0.8.0** (Milník 6: přenos souborů, viz [docs/PRENOS-SOUBORU.md](docs/PRENOS-SOUBORU.md)). Podrobnosti: [PLAN.md](PLAN.md), [README.md](README.md), [docs/HISTORIE.md](docs/HISTORIE.md), [docs/DISTRIBUCE.md](docs/DISTRIBUCE.md).

## Hotovo a ověřeno (na tomto MacBooku Pro, Apple Silicon, macOS 27.2)
- `swift test`: **247/247** (Milník 6 přidal 38 testů přenosu souborů s falešným telefonem; reálný test na S25 je volitelný přes `PURECLIPBOARD_REAL_PHONE`).
- `scripts/build-app.sh`: OK, v0.8.0 (CFBundleVersion 8), helper hlásí 0.8.0, `codesign --verify --strict --deep` OK (ad-hoc).
- `scripts/integration-test.sh`: **100/100** (reálná schránka, izolovaná konfigurace; `authorized_keys` beze změny).
- Historické verze (testy na zdrojových commitech): v0.1.0 12/12, v0.2.0 47/47, v0.3.0 110/110, v0.4.0 111/111, v0.5.0 134/134.
- Historie schránky (vypnutá ve výchozím stavu), ruční vykreslení obrazovek aplikace (`--render-screenshots`) zkontrolováno vizuálně.
- Testovací DMG: `dist/PureClipboard-0.7.0-arm64-adhoc-TEST.dmg` (verze 0.7.0; pro 0.8.0 zatím nevytvořen) (ad-hoc, **není notarizované, nepublikovat**); namontováno, obsah (app, Applications, návod, pozadí, rozložení) a `codesign` ověřeny, SHA-256 viz `dist/*.sha256`.

## Zbývá
- **Přenos souborů Mac → telefon (Milník 6) ověřen na skutečném S25 přes Wi‑Fi** (40 MB, pauza po 12,6 MB, pokračování od téhož místa, 7,3 MB/s, SHA-256 sedí). Neověřeno: kabel USB (odloženo). Rychlá akce „odeslat do S25“ předává soubory aplikaci (ověřeno malým souborem). Aplikace v `/Applications` obsahuje tuto funkci (přeinstalováno 30. 10. 2026).
- **Termux na skutečném S25 ověřen 30. 10. 2026** (uživatel, zrcadlení telefonu na Mac): `pcr frommac` doručil text do schránky telefonu (2×), `pcr tomac` doručil 23 znaků do přijaté pošty (v aplikaci čas 6:25:46, `rc=0`), prázdná schránka telefonu je odmítnuta bez přepsání. Dále ověřeno: návratový kód `pcr tomac` u prázdné schránky je 1; `pcr doctor` prošel (ssh ano, termux-api ano, pomocný program 0.7.0, spojení s Macem OK). Termux kanál je ověřen kompletně. Pozorování: vkládání dlouhých řádků z panelu Schránka klávesnice Samsung se přes zrcadlení komolilo (problém vstupu, ne kanálu).
- **Podepsané a notarizované DMG (Developer ID):** vyžaduje placený Apple Developer Program; postup v docs/DISTRIBUCE.md, neověřen proti Apple.
- Web: balík `web/pure-clipboard/` je připraven; živý web nebyl změněn; tlačítko ke stažení je neaktivní.
- Codex Desktop: ověřeno 30. 10. 2026 (uživatel poslal v aplikaci zprávu; `last-event-codex.json` ukázal novou událost 05:45:06Z, 4 znaky, `copied`/`ok`). Nepodporováno/neověřeno: Intel, Windows, Android, macOS starší než 27.

## Poznámka k historii Gitu
Autor všech commitů je `morfin83 <houslista.pavel@gmail.com>` – e-mail bude ve veřejné historii viditelný.
