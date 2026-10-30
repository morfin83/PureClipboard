# Změny

## 0.8.0
- **Přenos souborů Mac → telefon** v Pure Remote: soubory jdou do složky Stažené v telefonu po dílech přes `adb` (kabel USB, jinak Wi‑Fi). Lze je pozastavit a pokračovat bez nového začátku; u každého souboru je vidět průběh a rychlost.
- Hotový soubor se ověří SHA‑256 na telefonu a teprve potom se přesune do cíle; existující soubor se nepřepíše.
- Mobilní data se nepoužijí bez potvrzení.
- Rychlá akce „odeslat do S25“ předává soubory aplikaci (původní verze zálohovaná).
- Pomocný program: příkaz `transfer-enqueue`.

## 0.7.0 (2026-10-30)
- **Historie systémové schránky** (ve výchozím stavu vypnutá; sleduje jen po zapnutí a při běžící aplikaci): text, formátovaný text (RTF), obrázky, PDF, soubory a složky z Finderu (jen odkazy na originály).
- Hledání, obnovení do schránky, smazání položky i celé historie, pozastavení, limity (100 položek, 30 dní, 10 MB položka, 200 MB celkem; vše nastavitelné).
- Ochrana: sken citlivých údajů u textu (vždy), OCR na zařízení u obrázků a PDF (zvláštní souhlas), respektování označení soukromého/dočasného obsahu (správci hesel), oprávnění 0700/0600, atomické zápisy, odložení poškozeného indexu, zámek proti souběhu.
- Konfigurace: nový nepovinný oddíl `clipboardHistory`; starší soubory se načtou beze změny s vypnutou historií. `global.historyLimit` zůstává kvůli kompatibilitě, ale historie ho nepoužívá.
- Distribuce: `make-dmg.sh` s pozadím ve stylu PURE, označení ad-hoc testovacího DMG, `notarize.sh` po staplování přepočítá SHA-256.
- Nástroje: `PureClipboard --render-screenshots DIR` vykreslí snímky skutečných obrazovek s ukázkovými daty; webový balík `web/pure-clipboard`.

## 0.6.0
Termux: přenos textu mezi S25 a Macem na výslovný příkaz (Mac strana; reálný telefon viz STATUS.md).

## 0.5.0
Pure Remote (přehled Tailscale), příprava distribuce.

## 0.1.0 – 0.4.0
Konfigurace a GUI, Claude Code hook, Codex hook, Apple Terminal `pclip`, ruční kopírování.
