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

Další milníky: Codex, Terminal, Pure Remote, Termux, historie schránky.

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
