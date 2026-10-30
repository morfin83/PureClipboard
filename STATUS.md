# Pure Clipboard – stav projektu

Snímek ze **30. 10. 2026**, verze **0.7.0** (Milník 5). Podrobnosti: [PLAN.md](PLAN.md), [README.md](README.md), [docs/HISTORIE.md](docs/HISTORIE.md), [docs/DISTRIBUCE.md](docs/DISTRIBUCE.md).

## Hotovo a ověřeno (na tomto MacBooku Pro, Apple Silicon, macOS 27.2)
- `swift test`: **209/209** (z toho nové: historie, úložiště, zachytávání, monitor na soukromé schránce, obnovení, reálné OCR, metadata vydání).
- `scripts/build-app.sh`: OK, v0.7.0 (CFBundleVersion 7), helper hlásí 0.7.0, `codesign --verify --strict --deep` OK (ad-hoc).
- `scripts/integration-test.sh`: **100/100** (reálná schránka, izolovaná konfigurace; `authorized_keys` beze změny).
- Historické verze (testy na zdrojových commitech): v0.1.0 12/12, v0.2.0 47/47, v0.3.0 110/110, v0.4.0 111/111, v0.5.0 134/134.
- Historie schránky (vypnutá ve výchozím stavu), ruční vykreslení obrazovek aplikace (`--render-screenshots`) zkontrolováno vizuálně.
- Testovací DMG: `dist/PureClipboard-0.7.0-arm64-adhoc-TEST.dmg` (ad-hoc, **není notarizované, nepublikovat**); namontováno, obsah (app, Applications, návod, pozadí, rozložení) a `codesign` ověřeny, SHA-256 viz `dist/*.sha256`.

## Zbývá
- **Reálný test Termuxu na S25: dosud NEPROVEDEN** (čeká na kroky na telefonu). Do doby výsledku nepovažovat za ověřené (Mac strana ověřena simulací).
- **Podepsané a notarizované DMG (Developer ID):** vyžaduje placený Apple Developer Program; postup v docs/DISTRIBUCE.md, neověřen proti Apple.
- Web: balík `web/pure-clipboard/` je připraven; živý web nebyl změněn; tlačítko ke stažení je neaktivní.
- Nepodporováno/neověřeno: Intel, Windows, Android, Codex Desktop, macOS starší než 27.

## Poznámka k historii Gitu
Autor všech commitů je `morfin83 <houslista.pavel@gmail.com>` – e-mail bude ve veřejné historii viditelný.
