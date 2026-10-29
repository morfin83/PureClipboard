# Pure Clipboard

Nativní macOS aplikace PureStudio pro správu automatického kopírování do schránky.
Aktuální stav: Milník 2A (GUI, konfigurace a integrace Claude Code přes Stop hook; ostatní integrace zatím neaktivní). Viz [PLAN.md](PLAN.md).

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
