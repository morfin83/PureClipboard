# Přenos souborů do telefonu (Pure Remote)

Verze: 0.7.0+ (větev `milestone-6-file-transfer`). Směr: **Mac → telefon**. Cíl na telefonu: **Stažené** (`/sdcard/Download`).

## Co to umí
- Seznam přenosů v záložce **Pure Remote**: soubor, zdroj → cíl, velikost, průběh, **rychlost u každého souboru**, odhad zbývajícího času, cesta (**Kabel USB**, **Wi‑Fi**, **Mobilní data**).
- **Pozastavit / Pokračovat / Zrušit**. Pokračování **nezačíná znovu**: soubor se na telefonu skládá po dílech do jednoho dočasného souboru a velikost tohoto souboru říká, kolik už dorazilo. Totéž platí po výpadku spojení i po restartu aplikace nebo Macu.
- Hotový soubor se ověří **kontrolním součtem SHA-256** na telefonu a až potom se přesune do cíle. Existující soubor se **nikdy nepřepíše** (nový dostane `název (2).přípona`).
- Soubory lze přetáhnout do okna, vybrat tlačítkem, nebo předat z Finderu příkazem `pureclipboard-hook transfer-enqueue SOUBOR…` (Rychlá akce).
- Mobilní data: pokud je telefon dostupný jen přes mobilní síť (Wi‑Fi vypnutá), přenos se **pozastaví** a čeká na „Přesto poslat“.

## Jak to funguje
1. Aplikace najde `adb` (`/opt/homebrew/bin`, `/usr/local/bin`, Android SDK) a seznam zařízení. **Kabel má přednost**, jinak se použije adresa z pole „Adresa telefonu“ (`adb connect`).
2. Zdroj se zkontroluje (běžný soubor, velikost, čas změny) a spočítá se jeho SHA-256.
3. Na telefonu vznikne pracovní složka `/sdcard/Download/.pureclipboard/<id>/` s `data.part`.
4. Soubor se posílá po dílech (USB 64 MB, Wi‑Fi 16 MB, jinak 8 MB, mobilní síť 4 MB): `adb push` dílu, potom jednou příkazem připojení k `data.part` a vrácení velikosti. Selže‑li něco uprostřed, velikost `data.part` rozhodne, co se opakuje.
5. Po posledním dílu: SHA‑256 na telefonu, `mv` do cíle (bez přepsání), úklid pracovní složky.

Zdrojové soubory se jen čtou. Aplikace nepřidává žádný síťový kód ani poslouchající server; používá `adb`, který už na Macu běží. Stav přenosů je v `~/Library/Application Support/PureClipboard/transfers/` (0700/0600).

## Naměřeno (Mac ↔ Samsung S25, 200 MB)
| Cesta | Rychlost |
|---|---|
| LTE (Wi‑Fi v telefonu vypnutá) | 1,4 MB/s |
| Wi‑Fi (stejná síť, přímé spojení Tailscale) | 6,8 MB/s (po 8MB dílech 6,5 MB/s, režie dělení ≈ 4 %) |
| Kabel USB C–USB C | **neměřeno** (odhad 25–35 MB/s s USB 2.0, 60–150 MB/s s USB 3 kabelem) |

## Omezení a neověřeno
- Reálný test celé aplikace s pauzou a pokračováním na S25 čeká na zapnutý ADB přes Wi‑Fi (viz níže). Logika je pokryta testy s falešným telefonem.
- Kabel (USB) je připravený, ale **nebyl vyzkoušen**.
- Dílové posílání je sekvenční (jeden proud). Souběžné proudy a souběžný kabel + Wi‑Fi nejsou.
- Úložiště telefonu musí mít místo na velikost souboru + 64 MB.
- Obrázky se v Galerii nemusí objevit hned (Android si indexuje soubory sám).
- Bezdrátový ADB: port `5555` otevřený příkazem `adb tcpip 5555` se po restartu telefonu zavře. Alternativa: **Bezdrátové ladění** v nastavení pro vývojáře (adresa i port se tam zobrazí a mohou se měnit).

## Jak ověřit na reálném telefonu
```bash
PURECLIPBOARD_REAL_PHONE=100.92.44.15:5555 swift test --filter RealPhone
```
Test pošle jeden 40MB dočasný soubor, uprostřed ho pozastaví, naváže, ověří SHA‑256 na telefonu a smaže ho.

## Návrh úpravy Rychlé akce „odeslat do S25“ (zatím NEPROVEDENO)
Vaše akce dnes volá `adb push` sama a Pure Clipboard o ní neví. Aby se přenosy zobrazovaly v aplikaci a uměly pokračovat, stačí v kroku „Spustit shell skript“ (vstup: jako argumenty) nahradit obsah tímto. Původní skript se tím přestane používat; **změnu provedu až po Vašem potvrzení** a se zálohou původní akce.
```sh
HELPER="$HOME/Library/Application Support/PureClipboard/bin/pureclipboard-hook"
"$HELPER" transfer-enqueue "$@" && open -a "Pure Clipboard"
```
