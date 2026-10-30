# Pure Clipboard

Nativní macOS aplikace PureStudio se dvěma obrazovkami: **Pure Clipboard** pro kopírování textu na váš pokyn a **Pure Remote** pro živý přehled komunikace Tailscale.
Aktuální stav: Milník 2E (macOS). Aplikace pro Windows 11 a Android přijdou až po ověření Mac verze. Viz [PLAN.md](PLAN.md).

```bash
scripts/build-app.sh                         # sestaví build/PureClipboard.app
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Pro testování s kopií konfigurace lze cestu přepsat proměnnou `PURECLIPBOARD_CONFIG_PATH`.

## Ruční přenos mezi AI aplikacemi

Pure Clipboard používá společnou schránku macOS. Kopírování proběhne až na váš pokyn:

1. **Část odpovědi:** označte text v ChatGPT, Claude, Gemini, Terminálu nebo jiné aplikaci a stiskněte `⌘C`.
2. **Celá odpověď:** použijte tlačítko **Kopírovat** u odpovědi v dané aplikaci. V Claude Code v terminálu můžete použít `/copy`.
3. Přejděte do cílové aplikace (`⌘Tab`) a vložte pomocí `⌘V`.

Na Macu je klávesou pro kopírování `⌘`, nikoli `Ctrl`. V terminálu `Ctrl+C` přerušuje příkaz. Ruční kopírování přímo v jiné aplikaci zpracovává macOS; Pure Clipboard jeho obsah nečte ani nesleduje. Jestliže chcete, aby nové odpovědi Claude Code nebo Codexu samy nahradily schránku, zapněte **Auto Copy** a příslušnou integraci. Pro režim kopírování pouze na váš pokyn nechte **Auto Copy** vypnuté.

## Pure Remote na Macu

Přejděte v horní části aplikace na obrazovku **Pure Remote** a zapněte její přepínač. Aplikace pak každé dvě sekundy čte `tailscale status --json` z místního Macu. Zobrazuje dostupnost zařízení v tailnetu, typ aktuálního spojení a momentální rychlost odesílání a příjmu **mezi tímto Macem a každým zařízením**. Rychlost se počítá ze změny počítadel `TxBytes` a `RxBytes`; první vzorek proto ukazuje 0 B/s. Funkce vyžaduje nainstalovaný a přihlášený Tailscale s dostupným CLI. Po vypnutí přepínače nebo opuštění obrazovky monitorování skončí. Aplikace neukládá historii provozu.

Mac nemůže ze svého místního stavu změřit živý přenos mezi dvěma jinými zařízeními. Ten přijde až s aplikacemi na dalších platformách. Ovládání připojení a vzdálené probouzení zatím nejsou součástí této obrazovky.

Nastavení „Historie schránky“ je zatím jen příprava; obsah schránky se neukládá.

## Zapnutí integrace Claude Code

1. Spusťte aplikaci, zapněte **Auto Copy** i **Claude Code**.
2. V kartě „Claude Code – hook“ klikněte na **Nainstalovat hook** a potvrďte plán změn (záloha nastavení se vytvoří automaticky).
3. Restartujte běžící relace Claude Code (nebo počkejte na znovunačtení nastavení).

Terminálově (bez `--apply` jen ukáže plán):

```bash
build/PureClipboard.app/Contents/MacOS/pureclipboard-hook install-claude --apply
build/PureClipboard.app/Contents/MacOS/pureclipboard-hook status-claude
build/PureClipboard.app/Contents/MacOS/pureclipboard-hook uninstall-claude --apply
```

Test proti reálné schránce (neškodný text, vaše schránka se uloží a obnoví): `scripts/integration-test.sh`

## Zapnutí integrace Codex

1. V aplikaci zapněte **Auto Copy** i **Codex**.
2. V kartě „Codex – hook“ klikněte na **Nainstalovat hook** a potvrďte plán změn. Zapíše se jen `~/.codex/hooks.json` (záloha se vytvoří); `config.toml` a vaše `notify` zůstávají beze změny.
3. **Spusťte Codex, zadejte `/hooks` a nový hook schvalte.** Dokud ho neschválíte, Codex ho přeskakuje.
4. První skutečné kopírování uvidíte v kartě v řádku „Poslední událost“. Tlačítko „Otestovat (bez zápisu)“ ověří jen nastavení, nic nekopíruje.

Terminálově: `pureclipboard-hook install-codex --apply` (bez `--apply` jen plán), `status-codex`, `uninstall-codex --apply`.

Codex Desktop a IDE rozšíření zatím nejsou ověřeny.

## Souběh více agentů

Když více relací (Claude Code, Codex) skončí téměř současně, drží schránku ta, která kopírovala první: jiná relace ji během 5 sekund nepřepíše. Zápisy jsou serializované zámkem.

## Apple Terminal: příkaz `pclip`

Terminal.app neposkytuje oficiální událost s výstupem příkazů a čtení okna by bylo sledování obrazovky. Kopíruje se proto jen příkaz, který sami spustíte přes obal:

```bash
pclip swift build
```

1. Zapněte **Apple Terminal**. Přepínač **Auto Copy** může zůstat vypnutý, protože `pclip` spouštíte výslovně vy.
2. V kartě „Apple Terminal – příkaz pclip“ klikněte na **Nainstalovat pclip** a potvrďte plán (na konec `~/.zshrc` se po záloze připíše jediný označený blok; vaše řádky se nemění).
3. Otevřete nové okno Terminálu. Příkaz `pclip` vrací stejný kód jako obalený příkaz; výstup se zkopíruje jen bez hesel a tokenů (při chybě s řádkem `[exit N]`).

Terminálově: `pureclipboard-hook install-terminal --apply` (bez `--apply` jen plán), `status-terminal`, `uninstall-terminal --apply`. Váš stávající `cliprun` zůstává beze změny.
