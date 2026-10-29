# Pure Clipboard Manager — projektový plán

## Milník 1 — grafické rozhraní a konfigurace ✅

- Nativní SwiftUI aplikace (Swift Package, macOS 14+, Apple Silicon).
- Načítání `~/Library/Application Support/PureClipboard/config.json` přes typově bezpečné `Codable` modely.
- Atomické ukládání (dočasný soubor + `rename`), oprávnění 0600, ověření struktury a hodnot před zápisem.
- Neznámé klíče JSON se při uložení zachovávají (na všech úrovních).
- Při chybě načtení se soubor nepřepisuje; úpravy jsou zablokované.
- Ochrana proti souběžné externí změně (SHA-256 otisk) a odmítnutí zápisu přes symbolický odkaz.
- Přepínače pouze mění konfiguraci; žádné integrace ani procesy nejsou aktivní.

Další milníky (rozsah upřesní zadavatel): skutečné integrace, historie schránky, detekce citlivých údajů.

## Milník 2A — integrace Claude Code (Stop hook) ✅

- Oficiální hook `Stop` (https://code.claude.com/docs/en/hooks): vstup JSON na stdin obsahuje `last_assistant_message` (finální text odpovědi), proto se nečte transcript ani obrazovka.
- Pomocný program `pureclipboard-hook claude-stop` **vždy končí kódem 0 a nic nevypisuje**; nikdy neblokuje Claude Code.
- Kopíruje jen když: čitelná a platná `config.json`, `global.autoCopy` i `integrations.claudeCode.enabled` jsou `true`, událost je `Stop`, zpráva existuje, není prázdná ani > 200 000 znaků a (při zapnuté ochraně) neobsahuje citlivé údaje. Cokoli jiného = schránka se nezmění.
- Detekce citlivých údajů (`SensitiveDataScanner`): privátní klíče, AWS/GitHub/Slack/Stripe/Google/`sk-` klíče, JWT, Authorization/Bearer, URL s přihlašovacími údaji, přiřazení `password/secret/token/api_key = …`, dlouhé vysoce entropické řetězce. Hlásí jen názvy pravidel, nikdy obsah. Při pochybnostech se nekopíruje.
- `last-event.json` (0600, vedle `config.json`) obsahuje jen metadata poslední události (čas, výsledek, důvod, počet znaků, názvy pravidel). Při vypnuté integraci se nezapisuje nic.
- Instalace/odebrání hooku: tlačítka v aplikaci nebo CLI (`pureclipboard-hook install-claude|uninstall-claude|status-claude [--apply] [--settings CESTA]`; bez `--apply` jen ukáže plán). Postup: záloha `~/.claude/settings.json` do `~/Library/Application Support/PureClipboard/backups/`, přidání jediného záznamu do `hooks.Stop` (cizí hooky zůstávají), atomický zápis se zachováním oprávnění, kontrola po zápisu (jinak automatické obnovení ze zálohy). Odmítne: neplatný JSON, neočekávanou strukturu, symbolický odkaz, souběžnou změnu.
- Pomocný program se při instalaci kopíruje do `~/Library/Application Support/PureClipboard/bin/` (stabilní cesta nezávislá na umístění `.app`); pokud je v aplikaci novější, UI doporučí aktualizaci.
- Vypnutí přepínačů hook nemaže: hook se spustí, hned skončí a schránku nezmění (Claude Code ho jako proces spustí vždy, dokud není odebrán).
- Aplikace sama žádný proces nespouští.

## Milník 2B — integrace Codex (Stop hook) ✅ (CLI dle dokumentace; end-to-end čeká na schválení uživatelem)

Průzkum (Codex CLI 0.165.0, dokumentace https://developers.openai.com/codex/hooks):
- `notify` v `config.toml` je jen jeden program a uživatel ho už používá (Codex Computer Use, `turn-ended`). **Nepřepisuje se ani nemění.** Pro Pure Clipboard se nepoužívá.
- Codex má oficiální hooky stejné struktury jako Claude Code. `Stop` dostává na stdin JSON s `last_assistant_message` (`string | null`), `session_id`, `turn_id`, `stop_hook_active`. Exit 0 s prázdným stdout = úspěch.
- Hooky se čtou z `~/.codex/hooks.json` (nebo inline `[hooks]` v `config.toml`), všechny vrstvy se sčítají. Pure Clipboard používá **jen `~/.codex/hooks.json`**; `config.toml` se nikdy nečte ani nezapisuje (jen se zjistí, zda obsahuje vlastní `[hooks]`, a uživatel se upozorní).
- **Hook musí uživatel v Codexu schválit** (`/hooks`; schválení je vázané na hash definice). Do schválení se hook přeskakuje (ověřeno: `codex exec` s neschváleným hookem běží a hook mlčky vynechá). Schválení za uživatele neprovádíme a nepoužíváme `--dangerously-bypass-hook-trust`. Příkaz hooku se při aktualizaci pomocného programu nemění (stabilní cesta), takže schválení přetrvá.
- Rozhraní: Codex CLI = podporováno dle dokumentace. Codex Desktop / IDE rozšíření: dokumentace neuvádí, zda hooky spouští, a nelze to bezpečně ověřit bez zásahu do uživatelského nastavení → **nepotvrzeno, neslibujeme**. Sdílený app-server daemon naznačuje stejné chování, ale není to ověřeno.

Implementace:
- Společný `StopHookHandler` pro Claude Code i Codex (`pureclipboard-hook claude-stop|codex-stop`); každá integrace má vlastní přepínač a vlastní soubor poslední události (`last-event.json` / `last-event-codex.json`).
- Instalátor (`HookTarget`) je společný: záloha (`codex-hooks-*.json`), kontrola konfliktů, atomický zápis, ověření po zápisu, odmítnutí symbolického odkazu/neplatného JSON. Pomocný program je jeden sdílený (`.../PureClipboard/bin/pureclipboard-hook`); smaže se až s poslední odebranou integrací.
- CLI: `install-codex|uninstall-codex|status-codex [--apply] [--settings CESTA]`. Bez `--apply` jen plán.
- GUI: karta Codex (stav, plán změn k potvrzení, instalace/odebrání, upozornění na schválení v `/hooks`, „Otestovat (bez zápisu)“ a „Test se schránkou…“ s potvrzením).

Souběh více agentů (Claude Code i Codex, více relací):
- Zápisy do schránky jsou serializované zámkem (`flock` na `clipboard.lock`); nezískání zámku do 2 s = nekopíruje.
- Ochrana proti přepsání: pokud jiná relace (jiný `session_id` nebo jiná integrace) zkopírovala před méně než 5 s, pozdější hook **nekopíruje** (`recent-copy-by-other-session`) a schránka zůstane beze změny. Stejná relace smí kopírovat hned znovu. Stav v `clipboard-claim.json` (0600).
- Omezení: v dávce více agentů zůstane první odpověď, ostatní se přeskočí (je to viditelné v kartě „Poslední událost“). Nesleduje se změna schránky uživatelem ani jinými aplikacemi (žádné sledování schránky).

Známá omezení Codexu: `last_assistant_message` může být `null` (pak se nekopíruje); `SubagentStop` se neregistruje; Codex při souběhu `hooks.json` a inline `[hooks]` při startu varuje.

## Milník 2C — Apple Terminal (příkaz `pclip`) ✅

Průzkum:
- Terminal.app ani zsh nemají oficiální událost s výstupem příkazu. `preexec`/`precmd` dávají jen příkaz a návratový kód. Čtení okna/historie přes AppleScript by bylo sledování obrazovky (zakázáno), pseudo-terminály a `exec > >(tee)` jsou křehké. **Podporovaný způsob = explicitní obal: uživatel sám spustí `pclip <příkaz>`.**
- `~/.zshrc` už načítá vlastní `~/.pure/bin/clipboard.zsh` (funkce `cliprun`). Zůstává beze změny a funguje vedle `pclip`.

Implementace:
- `pclip` (zsh funkce v souboru `~/Library/Application Support/PureClipboard/shell/pureclipboard.zsh`): spustí příkaz, výstup (stdout+stderr) zobrazí průběžně (`tee`), po skončení předá soubor pomocnému programu `terminal-copy`; vrací původní návratový kód příkazu; dočasný soubor (0600) se vždy smaže (`always`); bez pomocného programu příkaz prostě proběhne.
- `terminal-copy`: stejné brány jako hooky (config platná, Auto Copy, přepínač Terminal), čištění výstupu (ANSI/OSC sekvence, přepisování `\r`, řídicí znaky), **sken celého výstupu** na citlivé údaje (i části, která by se při zkrácení ustřihla), zkrácení na posledních 100 000 znaků se značkou, při nenulovém kódu řádek `[exit N]`. Vstup > 4 MB se nekopíruje. Vypíše na stderr jeden řádek o výsledku.
- Souběh: výslovná akce uživatele není blokována čerstvou kopií agenta, ale sama si schránku „zabere“ (agent do 5 s nepřepíše).
- Instalace do `.zshrc` jen s plánem a potvrzením: záloha, **pouze připsání** jednoho označeného bloku (`# >>> Pure Clipboard (Terminal) >>>` … `<<<`), žádný stávající řádek se nemění; odebrání vyjme jen blok (obnoví původní soubor); odmítne symbolický odkaz a poškozené/zdvojené značky; kontrola po zápisu s návratem ze zálohy. Sdílený pomocný program se smaže až s poslední integrací.
- CLI: `install-terminal|uninstall-terminal|status-terminal [--apply] [--settings .zshrc]`, `terminal-copy`.
- GUI: karta Apple Terminal (stav, plán, instalace/odebrání, test bez zápisu / se schránkou).

Omezení: kopíruje se jen výslovně obalený příkaz (žádné automatické sledování terminálu); přes `pclip` nejdou interaktivní programy (výstup jde přes rouru, bez TTY a barev); Terminal.app GUI nebylo ovládáno (testováno v reálném zsh); karta Terminal v aplikaci nebyla vizuálně zkontrolována (přístup ke screenshotu odmítnut), ověřeno kompilací a logikou.

## Milník 2D — ruční přenos mezi AI aplikacemi ✅

- Režim „až na můj pokyn“: Auto Copy vypne automatické hooky Claude Code a Codexu, ale nezakazuje ruční kopírování přes macOS ani výslovný příkaz `pclip`.
- Označený text se mezi ChatGPT, Claude, Gemini, Terminálem a dalšími aplikacemi přenáší pomocí systémových `⌘C`, `⌘Tab`, `⌘V`. Celá odpověď se kopíruje tlačítkem zdrojové aplikace; Claude Code v terminálu nabízí `/copy`. Pure Clipboard nesleduje schránku ani obrazovku jiných aplikací.
- `pclip` nyní vyžaduje platnou konfiguraci a zapnutou integraci Terminal, dále zachovává sken citlivých údajů, limity a zámek schránky. Auto Copy jej neblokuje.
- GUI vysvětluje rozdíl mezi automatickým a ručním kopírováním. Testy ověřují, že vypnuté Auto Copy stále blokuje hooky, ale dovolí výslovný `pclip`.
- Pro skutečné použití `pclip` je nutná jeho instalace z aplikace nebo pomocí `install-terminal --apply` po zobrazení plánu; instalace mění pouze vlastní označený blok v `~/.zshrc` a vlastní skript Pure Clipboard, se zálohou.

Další milníky: Pure Remote, Termux, historie schránky.

## Závazné požadavky na veřejnou distribuci

Stav: **pouze zaznamenáno — release zatím nevytvářet ani nepublikovat.**

1. **Instalační DMG** — finální DMG s rozvržením „přetáhněte aplikaci do Applications“ (odkaz na `/Applications`, pozadí v PureStudio stylu).
2. **Vlastní ikona** — ikona aplikace ve vizuálním stylu PureStudio (tmavý podklad, tyrkysový akcent), všechny velikosti v `AppIcon.icns` / asset katalogu.
3. **Identita a verzování** — stabilní bundle identifier `studio.pure.clipboard` (neměnit), sémantické verzování `CFBundleShortVersionString` + monotónně rostoucí `CFBundleVersion`; architektura připravená na budoucí mechanismus aktualizací (např. Sparkle s podepsaným appcastem).
4. **Ad-hoc podpis** — distribuce bez placeného Apple Developer Programu podepsaná ad-hoc (`codesign --sign -`).
5. **Budoucí Developer ID + notarizace** — build skripty připravit tak, aby šlo přepnout na podpis Developer ID (hardened runtime, entitlements) a notarizaci přes `notarytool` + `stapler`. **Ad-hoc podpis notarizaci nenahrazuje**: Gatekeeper takovou aplikaci při prvním spuštění zablokuje a uživatel ji musí ručně povolit.
6. **Kontrolní součet** — ke každému DMG zveřejnit SHA-256 (`shasum -a 256`).
7. **Instalační návod pro začátečníky** — krok za krokem (stažení, ověření SHA-256, otevření DMG, přetažení do Applications, první spuštění), včetně jasného upozornění na Gatekeeper u nenotarizované aplikace a postupu povolení přes Nastavení systému → Soukromí a zabezpečení → „Přesto otevřít“.
8. **Texty pro web PureStudio** — kompletní české texty veřejné stránky aplikace (název, claim, popis, funkce, soukromí a bezpečnost, systémové požadavky, instalace, stav podpisu, FAQ, changelog).
9. **Architektury** — primární distribuce pro Apple Silicon (arm64). Podporu Intel (x86_64 / universal binary) ověřit samostatně na Intel stroji před tím, než bude uvedena jako podporovaná.
