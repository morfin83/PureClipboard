# Galerie Pure Clipboard na webu

Stav: připraveno v repu `pure` (větev `web/clipboard-gallery`), **nasazení čeká na schválení**.

## Účel
Ukázat návštěvníkovi, co aplikace umí, na skutečných obrazovkách. Galerie nahrazuje samotný textový popis a doplňuje jej o ukázku klávesové zkratky.

## Obsah galerie (v pořadí)
1. **Kopírujte na váš pokyn** — záložka Pure Clipboard.
2. **Historie vypnutá ve výchozím stavu** — záložka Historie se zapnutou volbou „vypnuto“.
3. **Historie na vašem Macu** — záložka Historie s položkami.
4. **Pure Remote: telefon v jednom okně** — záložka Pure Remote, přenosy souborů do telefonu.
5. **Jedna zkratka, celá historie** — ⌥⌘V a rychlá historie (`app-quick-history`).

Všechny snímky jsou výstupem `PureClipboard --render-screenshots DIR`. Renderer používá vymyšlená ukázková data a nedotýká se konfigurace ani schránky uživatele.

## Chování na webu
- Galerie je na stránce aplikace `lab/pure-clipboard/`, pod hlavním popisem, před sekcí požadavků.
- Každý snímek je tlačítko. Kliknutí otevře snímek v plné velikosti v modálním okně (`gallery.js`, sdílený prohlížeč obrázků).
- Snímky mají `width`/`height` a `loading="lazy"`; na mobilu jsou v jednom sloupci.
- Klávesová zkratka je zobrazena jako tři klávesy (⌥ ⌘ V) a pod nimi snímek rychlé historie.
- Texty jsou v `web/src/content.json` (klíč `gallery`), v angličtině a češtině. Chybějící jazyk nesmí zůstat prázdný (testuje se).

## Pravidla pro snímky
- Pouze skutečné snímky aplikace z rendereru. Žádné smyšlené obrazovky vydávané za stav aplikace.
- Žádné osobní údaje, e-maily, skutečné cesty ani tokeny. Ukázková data jsou z rendereru.
- Šířka 1000 px (výška podle obrazovky), komprimovaný PNG. Klip hlavní obrazovky se ořezává na viditelnou část.
- Při změně vzhledu aplikace snímky znovu vyrenderovat a nahradit ve `web/public/assets/pure-clipboard/`.

## Postup změny
1. Sestavit aplikaci a spustit renderer do prázdné složky.
2. Zkopírovat snímky do `web/public/assets/pure-clipboard/` a zmenšit šířku na 1000 px.
3. Aktualizovat rozměry (`w`, `h`) v `content.json`.
4. Zkontrolovat texty v obou jazycích a build (`python3 web/build.py`, testy).
5. Ověřit v prohlížeči bez vodorovného posunu na úzké obrazovce a otevření snímku v plné velikosti.
