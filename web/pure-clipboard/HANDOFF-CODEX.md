# Předávací dokument pro Codex – stránka Pure Clipboard (PURE / Lab)

Stav: **podklady hotové, živý web nebyl upraven.** Referenční vzhled: https://www.studiopuresound.cz/cs/lab/usage-meter-pure/ (a `/en/`).

## Soubory (relativně k `web/pure-clipboard/`)
| Cesta | Obsah |
|---|---|
| `cs/index.html`, `en/index.html` | hotové samostatné stránky (světlá plocha #FAFAF8, Arial, fialový akcent #6B45D9, tmavý náhled aplikace) |
| `content/pure-clipboard.{cs,en}.json` | všechny texty: SEO, funkce, soukromí, požadavky, instalace, FAQ, changelog, popisky a alt texty obrázků |
| `source/build-pages.py` | generátor HTML z JSON (`python3 source/build-pages.py`) |
| `assets/pure-clipboard.css` | styly |
| `assets/pure-clipboard-icon-{1024,512}.png`, `apple-touch-icon.png`, `favicon-64.png` | ikona |
| `assets/app-preview.png`, `history-on.png`, `history-off.png`, `clipboard.png` | **skutečné** snímky aplikace (vykreslené `PureClipboard --render-screenshots`, ukázková data; UI aplikace je česky) |
| `assets/hero-preview.png`, `og-image.png` (= `pure-clipboard-og.png`) | ilustrační kompozice (označeno v popiscích) |
| `../../scripts/make-web-assets.swift` | editovatelný zdroj grafiky (z vykreslených snímků) |

## Doporučené umístění
`/cs/lab/pure-clipboard/` a `/en/lab/pure-clipboard/`; assety např. `/assets/pure-clipboard-*.png` (v HTML jsou relativní `../assets/…`, upravit na cílovou strukturu webu). Na kartu v přehledu Lab odkázat stejně jako u Usage Meter Pure. Logo PURE a hlavičku/patičku převzít z existující stránky.

## Co záměrně chybí – NEPUBLIKOVAT jako hotové
- **Tlačítko ke stažení je neaktivní** („Stažení připravujeme“). Aktivovat až po: Developer ID podpisu, notarizaci, staplování, ověření Gatekeeperem a zveřejnění **finálního** SHA-256 (viz `docs/DISTRIBUCE.md`). Odkaz a hash doplnit do `hero` (a do instalace); přidat `downloadUrl` do JSON-LD.
- Hodnoty: `{{DOWNLOAD_URL}}`, `{{SHA256}}`, kontakt/podpora, datum vydání, případné číslo finální verze.
- Testovací ad-hoc DMG (`dist/…-adhoc-TEST.dmg`) **nenabízet ke stažení**.

## Kontrolní seznam
- [ ] Texty CS/EN odpovídají `docs/HISTORIE.md` (výchozí stav vypnuto, OCR není záruka, soubory jen odkazy).
- [ ] Neuvádět Intel, Windows, Android, Codex Desktop jako podporované (podporováno: Apple Silicon, macOS 14+, ověřeno na 27).
- [ ] Obrázky mají alt texty a popisky (v JSON); ilustrace jsou označené.
- [ ] Doplnit `og:image` na skutečnou URL, `canonical` a `hreflang` jsou nastaveny.
- [ ] Zkontrolovat světlé zobrazení na mobilu (<820 px jednosloupec) a klávesnicový focus.
- [ ] Teprve po vydání: aktivovat download, přidat SHA-256, přepsat „Vývoj“ na číslo verze.
