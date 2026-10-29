# Pure Clipboard

Nativní macOS aplikace PureStudio pro správu automatického kopírování do schránky.
Aktuální stav: Milník 2B (GUI, konfigurace, integrace Claude Code a Codex přes Stop hooky; Terminal, Pure Remote a Termux zatím neaktivní). Viz [PLAN.md](PLAN.md).

```bash
scripts/build-app.sh                         # sestaví build/PureClipboard.app
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Pro testování s kopií konfigurace lze cestu přepsat proměnnou `PURECLIPBOARD_CONFIG_PATH`.

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
