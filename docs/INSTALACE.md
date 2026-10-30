# Pure Clipboard – návod k instalaci

Návod je psaný pro úplné začátečníky. Zabere asi 5 minut.

## Co potřebujete

- Mac s čipem Apple (M1 nebo novější).
- macOS 14 nebo novější. Aplikace byla zatím vyzkoušena jen na macOS 27, starší verze nejsou ověřené.
- **Macy s procesorem Intel zatím nejsou podporované.**

## 1. Stáhněte a ověřte soubor

Stáhněte soubor `PureClipboard-<verze>-arm64.dmg` z oficiální stránky PureStudio. Vedle odkazu ke stažení je uvedený kontrolní součet **SHA-256**. Ověřením se ujistíte, že se soubor cestou nepoškodil a nikdo ho nepozměnil.

1. Otevřete **Terminál** (Spotlight: `⌘ + mezerník`, napište „Terminál“).
2. Vložte tento příkaz (cestu upravte, pokud je soubor jinde než ve Stažených):

   ```bash
   shasum -a 256 ~/Downloads/PureClipboard-*-arm64.dmg
   ```

3. Porovnejte vypsaný řetězec s hodnotou na webu. **Musí být stejný znak od znaku.** Pokud se liší, soubor neotevírejte, smažte ho a stáhněte znovu.

## 2. Nainstalujte aplikaci

1. Dvakrát klikněte na stažený `.dmg`. Otevře se okno s ikonou **Pure Clipboard** a složkou **Applications**.
2. **Přetáhněte** ikonu Pure Clipboard na složku Applications.
3. Okno zavřete a disk vysuňte (v Finderu vlevo klikněte na symbol vysunutí u „Pure Clipboard“).
4. Spusťte aplikaci z **Applications** (ne přímo z disku).

## 3. První spuštění: upozornění macOS (Gatekeeper)

Pure Clipboard je zatím podepsaný jen **ad-hoc podpisem** a **není notarizovaný Applem**. Ad-hoc podpis neznamená, že Apple aplikaci zkontroloval, takže ji macOS při prvním spuštění zablokuje. Zobrazí se zpráva typu „Pure Clipboard nelze otevřít“ nebo „Apple nemůže zkontrolovat, zda neobsahuje malware“. To je očekávané. Povolit ji můžete takto:

1. Zprávu zavřete tlačítkem **Hotovo** (nebo **Zrušit**).
2. Otevřete **Nastavení systému → Soukromí a zabezpečení**.
3. Sjeďte dolů do části **Zabezpečení**. Uvidíte text, že byl „Pure Clipboard“ zablokován.
4. Klikněte na **Přesto otevřít**, potvrďte heslem nebo Touch ID a v dalším okně znovu klikněte na **Otevřít**.

Příště se aplikace otevře normálně. Povolení platí jen pro tuto verzi: po aktualizaci na novou verzi se může postup zopakovat.

> **Pokročilá alternativa (jen pro zkušené):** v Terminálu `xattr -d com.apple.quarantine "/Applications/Pure Clipboard.app"` odstraní příznak karantény. Používejte to **pouze** pro soubor, jehož SHA-256 jste ověřili v kroku 1.

Po získání placeného účtu Apple Developer se plánuje podepsání certifikátem Developer ID a notarizace. Tím upozornění odpadne. Do té doby platí tento postup.

## 4. První nastavení

Při prvním spuštění se aplikace nic nesnaží měnit. Nejdřív si ji prohlédněte:

- **Ruční kopírování funguje vždy:** označte text v libovolné aplikaci (ChatGPT, Claude, Gemini, Terminál…), stiskněte `⌘C`, přepněte se (`⌘Tab`) a vložte `⌘V`. Pure Clipboard při tom nic nečte ani nesleduje.
- **Auto Copy** zapíná volitelné samočinné kopírování finálních odpovědí z **Claude Code** a **Codexu**. Je vypnuté, pokud ho nezapnete.
- Každá integrace má v aplikaci vlastní kartu. **Žádná se neinstaluje sama.** U každé nejdřív uvidíte přesný plán změn a potvrdíte ho; před zásahem do cizího souboru se vytvoří záloha.
  - **Claude Code** – hook v `~/.claude/settings.json`.
  - **Codex** – hook v `~/.codex/hooks.json`. Po instalaci spusťte Codex, napište `/hooks` a nový hook **schvalte**; do té doby ho Codex přeskakuje. Codex Desktop zatím není ověřený.
  - **Apple Terminal** – příkaz `pclip` (do `~/.zshrc` se připíše jediný označený blok). Použití: `pclip swift build`; spustí příkaz a jeho výstup zkopíruje.
- **Pure Remote** (vyžaduje nainstalovaný Tailscale) ukazuje živý přehled spojení Tailscale na tomto Macu (čte jen místní stav, nic nemění). Historie schránky zatím není hotová.
- **Termux** (volitelné) umí posílat text mezi telefonem S25 a Macem, ale jen na váš příkaz `pcr` v Termuxu. Přijatý text se do schránky Macu dostane až tlačítkem **Kopírovat**. Postup a požadavky jsou v kartě „Termux – S25 ↔ Mac“ a v README; kanál se připravuje po zobrazení plánu a nic nemění v nastavení SSH. Na skutečném telefonu zatím nebyl vyzkoušen.
- **Ochrana citlivých údajů** (zapnutá): automatické kopírování přeskočí texty, které vypadají jako heslo, token nebo soukromý klíč.

## 5. Aktualizace

Automatické aktualizace zatím nejsou. Stáhněte novou verzi, ověřte SHA-256, přetáhněte aplikaci do Applications a potvrďte nahrazení. Poté otevřete aplikaci a u integrací, které hlásí „Doporučena aktualizace“, klikněte na **Aktualizovat**.

## 6. Odinstalace

1. V aplikaci u každé zapnuté integrace klikněte na **Odebrat** (hook / pclip). Vrátí se původní soubory, ostatní vaše položky zůstanou.
2. Ukončete aplikaci a přesuňte **Pure Clipboard** z Applications do koše.
3. Volitelně smažte složku `~/Library/Application Support/PureClipboard`. Je v ní konfigurace a **zálohy** vašich nastavení. Smažte ji až poté, co už zálohy nepotřebujete.

## Řešení potíží

| Problém | Co zkontrolovat |
|---|---|
| Nic se nekopíruje samo | Je zapnutý **Auto Copy** i přepínač dané integrace? Je hook nainstalovaný? V kartě integrace se podívejte na řádek **Poslední událost**: ukáže důvod přeskočení. |
| Text se přeskočil kvůli „citlivým údajům“ | Ochrana našla něco, co vypadá jako heslo či token. To je záměr; zkopírujte ručně `⌘C`, pokud víte, že je to bezpečné. |
| Codex nekopíruje | Hook musí být schválený v Codexu: `/hooks`. |
| `pclip: command not found` | Otevřete **nové** okno Terminálu (nebo spusťte `source ~/.zshrc`). |
| macOS aplikaci opět blokuje | Po aktualizaci zopakujte krok 3. |

## Soukromí

Pure Clipboard **nepoužívá internet**, neposílá nikam data ani statistiky, nečte obsah schránky ostatních aplikací a nemá žádné účty. Ukládá jen vaše nastavení a metadata poslední události (čas, výsledek, počet znaků), nikdy obsah zkopírovaného textu. Výjimky jsou dvě: `pclip` (výstup příkazu se na okamžik zapíše do dočasného souboru čitelného jen vámi a po dokončení příkazu se smaže) a Termux (text čekající v přijaté nebo odesílané poště, v soukromé složce, nejdéle hodinu; odebráním kanálu se smaže hned).
