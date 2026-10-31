# Záznam vydání

Provozní přehled každé verze: tag, commit, build, stav distribuce a schválení. Co se v jednotlivých verzích změnilo, je v [CHANGELOG.md](CHANGELOG.md). Podle [CLAUDE.md](CLAUDE.md) se tento soubor doplňuje při každé verzi.

**Pravidla**
- Testovací ad-hoc DMG (`…-adhoc-TEST`) se **nezveřejňuje** jako oficiální stažení. Pre-release na GitHubu jen s označením testovací verze a po schválení vlastníka.
- Notarizace se neoznačuje jako hotová, dokud ji Apple nepotvrdí (zatím se neověřuje, viz [docs/DISTRIBUCE.md](docs/DISTRIBUCE.md)).
- Tag je zdrojový (`bez DMG`), ne vydání. Vytvoření tagu nebo GitHub Release vyžaduje výslovný souhlas.

| Verze | Build | Tag | Commit | Datum | Distribuce | Poznámka |
|---|---|---|---|---|---|---|
| 0.1.0 | 1 | `v0.1.0` | `7db6a79` | 2026-10-29 | jen zdroje | Milník 1: GUI a bezpečná konfigurace |
| 0.2.0 | 2 | `v0.2.0` | `6ddd642` | 2026-10-29 | jen zdroje | Milník 2A: Claude Code (oficiální Stop hook) |
| 0.3.0 | 3 | `v0.3.0` | `7fd18e1` | 2026-10-29 | jen zdroje | Milník 2C: Apple Terminal (`pclip`) |
| 0.4.0 | 4 | `v0.4.0` | `ab6c9b3` | 2026-10-30 | jen zdroje | Milník 2D: ruční kopírování |
| 0.5.0 | 5 | `v0.5.0` | `1e569ec` | 2026-10-30 | jen zdroje | Milník 3: příprava distribuce, Pure Remote |
| 0.6.0 | 6 | `v0.6.0` | `3047a4c` | 2026-10-30 | jen zdroje | Milník 4: Termux (Mac strana) |
| 0.7.0 | 7 | `v0.7.0` | `ccab8c2` | 2026-10-30 | lokální testovací ad-hoc DMG (`dist/`, nepublikováno) | Milník 5: historie systémové schránky |
| 0.8.0 | 8 | `v0.8.0` | `0d91ca0` | 2026-10-30 | jen zdroje (DMG zatím nevytvořen) | Milník 6: přenos souborů do telefonu |

**Ověřeno na zařízeních:** 0.6.0 Termux, 0.7.0 Codex Desktop, 0.8.0 přenos souborů na S25 přes Wi‑Fi. Podrobně [STATUS.md](STATUS.md).

**Nepodporováno/neověřeno:** Intel, Windows, Android aplikace, macOS starší než 27.
