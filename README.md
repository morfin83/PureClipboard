# Pure Clipboard

Nativní macOS aplikace PureStudio pro správu automatického kopírování do schránky.
Aktuální stav: Milník 1 (GUI + konfigurace, integrace zatím neaktivní). Viz [PLAN.md](PLAN.md).

```bash
scripts/build-app.sh                         # sestaví build/PureClipboard.app
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Pro testování s kopií konfigurace lze cestu přepsat proměnnou `PURECLIPBOARD_CONFIG_PATH`.
