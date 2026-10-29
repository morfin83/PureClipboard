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
