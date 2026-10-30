# Pure Clipboard – stav projektu

Snímek ze **30. 10. 2026** (aktualizováno po Milníku 3). Sestaveno z Gitu, testů a read-only kontroly Macu po tom, co část práce proběhla v GPT. Podrobnosti o jednotlivých milnících jsou v [PLAN.md](PLAN.md), návody v [README.md](README.md). Tento soubor záměrně nemění PLAN.md, protože ten se právě upravuje v rozpracovaném Milníku 2E.

## 1. Kde co leží (Git)

```
(větev milestone-3-distribution)  Milník 3  příprava distribuce: ikona, skripty, dokumenty — bez DMG   v0.5.0
38e29e4  Milník 2E  Pure Remote na Macu (přehled Tailscale)      v0.5.0   ← main, milestone-2e-pure-remote-mac
ab6c9b3  Milník 2D  ruční kopírování a pclip bez Auto Copy        v0.4.0   ← milestone-2d-manual-copy
7fd18e1  Milník 2C  Apple Terminal (příkaz pclip)                  v0.3.0   ← milestone-2c-terminal
85deaef  Milník 2B  Codex (Stop hook)                              v0.3.0   ← milestone-2b-codex
6ddd642  Milník 2A  Claude Code (Stop hook)                        v0.2.0   ← milestone-2a-claude-hook
7db6a79  Milník 1   GUI + bezpečná konfigurace                     v0.1.0   ← tag backup/main-before-2a-2e
```

- Všechny milníky jsou lineární řetěz. **`main` byl 30. 10. 2026 lokálně posunut (fast-forward) na Milník 2E**; původní `main` (Milník 1) zůstává pod tagem `backup/main-before-2a-2e`. Nic není pushnuto (repozitář nemá remote). Starší větve 2A–2D zůstávají jako pojmenované body historie.
- `STATUS.md` vznikl na větvi `docs/project-status` (z `ab6c9b3`) a do `main` byl 30. 10. 2026 přidán jedním commitem; větev zůstává jako záznam historie změn tohoto souboru.
- **Milník 2E „Pure Remote na Macu“, v0.5.0 – commitnuto** na větev `milestone-2e-pure-remote-mac` (nad `ab6c9b3`) po opravách z bodů 4 a 6 tabulky níže. Větev je zároveň rozcheckovaná ve vedlejším worktree (složka `PureClipboard-manual` v dočasné složce aplikace Claude); commit tedy přežije i smazání té složky, protože je v tomtéž repozitáři.

## 2. Co bylo ověřeno

| Stav | Testy | Sestavení | Integrační skript |
|---|---|---|---|
| 2D, commit `ab6c9b3` | `swift test` **111/111** | `build-app.sh` OK (v0.4.0) | **75/75** (reálná schránka, reálný zsh) |
| 2E, commitnuto (po opravách) | `swift test` **123/123** | release build OK (v0.5.0, verze v plistu i helperu souhlasí) | **75/75** (helper z `.build`, bez zásahu do běžící aplikace) |

Starší ověření: 2A–2C viz reporty v PLAN.md (Claude Code ověřen v reálném provozu uživatelem; Codex CLI ověřen v reálném provozu, poslední kopie 22:36 UTC; Codex Desktop/IDE **stále neověřeno**).

## 3. Skutečný stav na Macu (read-only kontrola)

- `~/.claude/settings.json`: hook Stop Pure Clipboard **nainstalován** (1 záznam, žádné jiné Stop hooky). Poslední kopie 23:21 UTC (1 188 znaků).
- `~/.codex/hooks.json`: hook **nainstalován**; v `config.toml` je navíc vlastní `[hooks]` (zřejmě záznam schválení v `/hooks`); Codex ho sloučí a při startu na to upozorní. `notify` v `config.toml` nepatří nám a nikdo jej nezměnil.
- `~/.zshrc`: blok Pure Clipboard (Terminal) **přidán**, ostatní řádky (včetně `source ~/.pure/bin/clipboard.zsh`) beze změny. `pclip` je od 30. 10. ověřen v reálném zsh (viz bod 7); skript v `shell/` je jen o verzi starší (liší se komentářem s číslem verze), proto karta hlásí „starší verze“.
- `config.json` (0600): `autoCopy=true`, `historyLimit=100`, ochrana citlivých údajů zapnutá, **všech pět integrací `enabled=true`** (Pure Remote a Termux jen jako přepínač).
- Sdílený pomocný program v `~/Library/Application Support/PureClipboard/bin/` je **v0.5.0** (nainstalován z buildu rozpracovaného 2E). Běžící aplikace (pid 36715) je právě ten 0.5.0 build z worktree.
- LaunchAgent `cz.pure.remote.awake` (`caffeinate -s`) běží beze změny. Tailscale CLI je v `/usr/local/bin/tailscale`.

## 4. Rozhodnutí, která padla v GPT (platí pro další práci)

1. **Ruční kopírování je hlavní způsob.** Text se mezi ChatGPT, Claude, Gemini, Terminálem přenáší systémovým `⌘C` / tlačítkem Kopírovat / `⌘V`; Pure Clipboard jeho obsah nečte ani nesleduje. Automatické hooky Claude Code a Codexu jsou **volitelné** a řídí je Auto Copy.
2. **`pclip` nezávisí na Auto Copy** (od 2D). Stačí zapnutá integrace Apple Terminal; zůstává sken citlivých údajů, limity a zámek.
3. **Pure Remote NENÍ kopírování výsledků akcí.** Znamená přehled provozu Tailscale na Macu: stav zařízení, přímé/reléové spojení, rychlost odesílání a příjmu mezi Macem a každým zařízením (čte `tailscale status --json` každé 2 s, jen při zapnutém přepínači a otevřené obrazovce; bez historie, bez zásahu do Tailscale). Dřívější návrh promptu „Pure Remote = `actionResults` kopírování do schránky“ je **neplatný**.
4. **Plán dál:** dokončit a ověřit oba moduly na Macu → samostatné aplikace pro Windows 11 a Android → přenos textu na jedno vybrané zařízení a přehled komunikace i mezi ostatními zařízeními. Termux v konfiguraci zatím jen přepínač bez funkce (jeho role se nejspíš spojí s Android aplikací; nerozhodnuto).
5. **Historie schránky** je pořád jen nastavený limit (karta je v 2E označena „připravuje se“).

## 5. Nalezené nesrovnalosti a rizika

| # | Co | Doporučení |
|---|---|---|
| 1 | ~~2E není commitnuté~~ **Vyřešeno:** 2E je commitnuté na `milestone-2e-pure-remote-mac`. | – |
| 2 | ~~PLAN.md a README.md se měnily ve dvou místech~~ **Vyřešeno:** 2D i 2E jsou ve stejném řetězci a v `main`. | – |
| 3 | **Posun verzí pomocného programu:** nainstalovaný je 0.5.0, build z 2D má 0.4.0 → tlačítko „Aktualizovat“ z 2D buildu by pomocný program **vrátilo na starší verzi**. | Aplikaci spouštět z buildu 2E (0.5.0) nebo 2E nejdřív slučit. Kartám Claude/Codex/Terminal teď hlásí „starší/neaktuální“ právě jen kvůli tomuto rozdílu. |
| 4 | ~~Zastaralý text v 2E~~ **Opraveno:** hláška nově odkazuje na přepínač na kartě. | – |
| 5 | ~~Pojmenování `actionResults`~~ **Zdokumentováno** v PLAN.md a pokryto testem (uložená hodnota zůstává kvůli kompatibilitě). | – |
| 6 | **2E spouští proces** (`tailscale status --json` každé 2 s) – dřívější záruka „aplikace sama nespouští žádné procesy“ už neplatí. Je omezeno na zapnutý přepínač a obrazovku Pure Remote a zápatí bylo správně změněno; **Dokumentace bezpečnostního modelu doplněna** do PLAN.md (pevné cesty, bez shellu, timeout 5 s, žádný zápis); samotný proces `tailscale` unit testem pokrytý není (ověřeno ručně na spojení Mac ↔ S25). | Případně doplnit integrační test. |
| 7 | ~~`pclip` nebyl reálně ověřen~~ **Ověřeno 30. 10. 2026 ve skutečném interaktivním zsh** (váš `~/.zshrc`, nainstalovaný helper 0.5.0, skutečná konfigurace): úspěšný příkaz se zkopíroval a vrátil kód 0; selhávající příkaz vrátil původní kód 3 a do schránky přidal `[exit 3]`; falešný token se nezkopíroval (schránka beze změny, událost `sensitive-content`). Okno Terminal.app samo ovládáno nebylo. | – |
| 8 | **Codex Desktop/IDE** nepotvrzeno; schválení hooku probíhá jen v Codex CLI. | Beze změny do ověření. |
| 9 | ~~Veřejná distribuce nezačala~~ **Připraveno (Milník 3):** ikona, skripty (DMG/SHA-256/notarizace – jen plán), návod, texty pro web. **DMG ani release nevznikly**; Developer ID/notarizace neověřeny proti Apple; Intel neověřen. | Až na pokyn: `make-dmg.sh --create`, test na čistém účtu, pak vydání. |

## 6. Doporučené pořadí

1. ~~Commitnout 2E~~ (hotovo).
2. ~~Sloučit řetěz 2A → 2E do `main`~~ (hotovo lokálně; bez pushe a bez release). `STATUS.md` je i v `main`.
3. ~~Ověřit `pclip`~~ (hotovo); případně ještě Codex Desktop.
4. Rozhodnout osud Termuxu a historie schránky.
5. Teprve potom distribuce (DMG atd.) a aplikace pro Windows 11 / Android.
