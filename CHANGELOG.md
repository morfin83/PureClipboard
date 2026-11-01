# Změny

## 0.8.1
- Oprava: po změně adresy telefonu v Pure Remote se nově zadaná adresa použije i pro stahování a seznam ze S25 (dřív se projevila jen u odesílání).
- Telefon se po restartu může objevit na jiném portu. Aplikace ho hledá na místní síti podle sériového čísla (mDNS) a uloží aktuální adresu. Když telefon není na stejné síti (mobilní data, hotspot), zadejte port z Bezdrátového ladění ručně.
- Po uložení adresy se hned ověří připojení a zobrazí výsledek.
- Verze 0.8.1 (build 9).

## 0.8.0
- **Přenos souborů Mac → telefon** v Pure Remote: soubory jdou do složky Stažené v telefonu po dílech přes `adb` (kabel USB, jinak Wi‑Fi). Lze je pozastavit a pokračovat bez nového začátku; u každého souboru je vidět průběh a rychlost.
- Hotový soubor se ověří SHA‑256 na telefonu a teprve potom se přesune do cíle; existující soubor se nepřepíše.
- Mobilní data se nepoužijí bez potvrzení.
- Rychlá akce „odeslat do S25“ předává soubory aplikaci (původní verze zálohovaná).
- Stahování z telefonu do Macu (Pure Remote → Z telefonu do Macu): výpis složky Stažené, stažení po dílech s pauzou a pokračováním, kontrola SHA-256, soubor se uloží do `~/Downloads` bez přepsání.
- Rychlá historie schránky klávesovou zkratkou ⌥⌘V (vyžaduje zapnutou historii); Enter zkopíruje položku, nic se nevkládá automaticky.
- Oznámení na Macu při dokončení, selhání nebo čekání přenosu na mobilní data či telefon.
- Fotky a videa přenesené do telefonu se indexují pro Galerii.
- Pomocný program: příkaz `transfer-enqueue`.
- Testy: 287 (CI workflow `.github/workflows/tests.yml`, zatím neověřený na GitHubu).

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
