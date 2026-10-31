# Nasazení webu Pure Clipboard (příprava)

Stav: **připraveno, NENASAZENO.** Nasazení na produkci (studiopuresound.cz) vyžaduje výslovný souhlas vlastníka (viz CLAUDE.md). Tento soubor nic nespouští.

## Co se nasadí
`scripts/make-web-bundle.sh` vytvoří `dist/web-bundle/` a `dist/pure-clipboard-web-bundle.zip`:
- `cs/lab/pure-clipboard/index.html` → https://www.studiopuresound.cz/cs/lab/pure-clipboard/
- `en/lab/pure-clipboard/index.html` → https://www.studiopuresound.cz/en/lab/pure-clipboard/
- `assets/pure-clipboard/*` (ikony, snímky, CSS, OG obrázek) → `/assets/pure-clipboard/…`

Skript před zabalením kontroluje: žádné nevyplněné zástupné hodnoty `{{NAZEV}}`, žádný odkaz na DMG a kanonické adresy odpovídají cílové struktuře. Při chybě skončí s hlášením.

## Co zatím NESMÍ být na webu
- **Aktivní tlačítko ke stažení.** Stránka ukazuje „Stažení připravujeme“. Aktivovat až po Developer ID podpisu, notarizaci, staplování, ověření Gatekeeperem a zveřejnění konečného SHA-256 (viz docs/DISTRIBUCE.md).
- Odkaz na testovací ad-hoc DMG. Ten se nenabízí ke stažení nikdy.
- Tvrzení o notarizaci nebo ověření Applem.

## Postup nasazení (až po souhlasu)
1. `zsh scripts/make-web-bundle.sh` na čistém `main`; výstup ověřte (`dist/web-bundle`).
2. Nahrát obsah `dist/web-bundle/` na server do kořene webu (ne do podsložky). Zachovat strukturu.
3. Ověřit: obě stránky se otevřou, obrázky a CSS se načtou (bez 404), `og:image` je dostupný na `https://www.studiopuresound.cz/assets/pure-clipboard/pure-clipboard-og.png`, přepínání CS/EN funguje.
4. Zkontrolovat mobil (<820 px) a klávesnicový fokus.
5. Ověřit, že v HTML nejsou žádné testovací údaje ani lokální cesty.

## Návrat zpět
Předchozí verzi stránek ponechat na serveru (nebo mít zálohu). Při chybě obnovit zálohu; nic jiného na webu se nemění.

## Co je potřeba od vlastníka
- Souhlas s nasazením (konkrétní adresy `/cs/lab/pure-clipboard/` a `/en/lab/pure-clipboard/`).
- Přístup k serveru nebo způsob nahrání (FTP/SFTP/CMS). Tyto přístupy si nebudu vyžadovat ani ukládat.
- Kontakt a podpora pro stránku (`{{KONTAKT}}` v textech, pokud se objeví).
