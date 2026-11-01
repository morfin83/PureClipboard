# Přenos souborů do telefonu (Pure Remote)

Verze: 0.8.0 (větev `milestone-6-file-transfer`). Směr: **Mac → telefon**; opačný směr **telefon → Mac** je popsán v sekci „Z telefonu do Macu“ níže. Cíl na telefonu: **Stažené** (`/sdcard/Download`).

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
- Ověřeno na skutečném S25 přes Wi‑Fi (30. 10. 2026): 40MB soubor, pauza po 12,6 MB, pokračování od téhož místa, průměr 7,3 MB/s, SHA‑256 na telefonu sedí, dočasný soubor i pracovní složka smazány. Logika je navíc pokryta testy s falešným telefonem.
- Kabel (USB) je připravený, ale **nebyl vyzkoušen**.
- Dílové posílání je sekvenční (jeden proud). Souběžné proudy a souběžný kabel + Wi‑Fi nejsou.
- Úložiště telefonu musí mít místo na velikost souboru + 64 MB.
- Fotky a videa: po přenosu aplikace pošle telefonu broadcast `MEDIA_SCANNER_SCAN_FILE` (jen přípony obrázků, videa a zvuku). Ověřeno na S25 (30. 10. 2026): broadcast vrací `result=0` a soubor je v indexu MediaStore do několika sekund i bez něj; broadcast je tedy jen pojistka.
- Bezdrátový ADB: port `5555` otevřený příkazem `adb tcpip 5555` se po restartu telefonu zavře. Alternativa: **Bezdrátové ladění** v nastavení pro vývojáře (adresa i port se tam zobrazí a mohou se měnit).

## Jak ověřit na reálném telefonu
```bash
PURECLIPBOARD_REAL_PHONE=100.92.44.15:5555 swift test --filter RealPhone
```
Test pošle jeden 40MB dočasný soubor, uprostřed ho pozastaví, naváže, ověří SHA‑256 na telefonu a smaže ho.

## Z telefonu do Macu

Stav: **NAVRŽENO** a ověřeno testy s falešným telefonem (`PullEngineTests`, `PullAdbLayerTests`). Na reálném telefonu **NEOVĚŘENO**.

- Karta přenosů má sekci **Z telefonu do Macu**. Tlačítko **Načíst seznam** vypíše běžné soubory ze `/sdcard/Download` (jméno, velikost, čas změny). Seznam se nenačítá automaticky.
- **Stáhnout** u souboru je vždy výslovné kliknutí a stáhne jen ten soubor. Hotový soubor se objeví v **~/Downloads**.
- Postup: 1) na telefonu se ověří velikost a čas proti seznamu, jinak se nic nestahuje; 2) SHA‑256 se spočítá na telefonu (`sha256sum`); 3) rozsahy bajtů se čtou přes `adb exec-out` (`tail -c +N | head -c L`) a zapisují do `…/transfers/pull/<id>.part` na Macu. Velikost `.part` říká, odkud pokračovat; 4) po posledním dílu se SHA‑256 lokální kopie porovná s telefonem; 5) teprve pak se soubor připojí do ~/Downloads pod volným názvem (`foto (2).jpg`). Připojení pomocí `link(2)` nikdy nepřepíše existující soubor a pracovní `.part` se smaže.
- Pauza, zrušení, výpadek, chybějící telefon a mobilní data fungují stejně jako u odesílání. Výpadek při dílu pozastaví přenos s důvodem a pokračuje od posledního dílu. Čtení nemá vedlejší účinky, takže ztracená odpověď se jen zopakuje a bajty se nezdvojí.
- Bezpečnost: čte se jen běžný soubor přímo ve `/sdcard/Download`. Cesty mimo tuto složku, jména s `/` nebo `..` a skryté soubory (včetně `.pureclipboard`) se odmítnou. Zdrojový soubor na telefonu se nemění ani nemaže.
- Úlohy mají pole `direction` (`push` / `pull`). Starší uložené úlohy bez tohoto pole se načtou jako `push` (ověřeno testem `jobsSavedBeforePullsDecodeAsPush`). Oba enginy čtou stejné úložiště, ale každý zpracuje jen svůj směr.
- Omezení: výpis a čtení přes `tail -c +N` mohou být u velkých souborů s rostoucím offsetem pomalejší (neměřeno). Notifikace systému se pro stahování zatím nezobrazují.
- Reálný test (**NAVRŽENO, neprovedeno**): stáhnout malý soubor, který uživatel sám položí do Stažených v telefonu, pozastavit ho uprostřed a pokračovat. Ověřit, že v ~/Downloads vznikl soubor se stejným SHA‑256 jako na telefonu.

## Adresa telefonu a port (0.8.1)
Bezdrátové ladění na Androidu mění port po každém restartu telefonu. IP adresa v Tailscale (`100.x.x.x`) zůstává stejná, mění se jen port. Port nejde na telefonu bez kabelu a root oprávnění uzamknout.

Aplikace postupuje takto:
1. Zkusí uloženou adresu `IP:port`.
2. Když neodpoví, najde telefon přes mDNS (`adb mdns services`) podle sériového čísla uloženého při prvním připojení a připojí se na aktuální port. Funguje to jen tehdy, když je telefon na místní síti s Macem (stejná Wi‑Fi nebo hotspot telefonu).
3. Když telefon není na místní síti (mobilní data), port se musí zadat ručně z Bezdrátového ladění.

Po uložení adresy aplikace hned ověří připojení a zobrazí výsledek. Nová adresa a sériové číslo se uloží.

## Rychlá akce „odeslat do S25“ (Finder)
Od 30. 10. 2026 akce **předává soubory aplikaci**, nepřenáší je sama. Akce je v `~/Library/Services/odeslat do S25.workflow`; původní verze je zálohovaná v `~/Library/Application Support/PureClipboard/backups/quick-action-*`.

Akce zavolá `pureclipboard-hook transfer-enqueue SOUBOR…`, aplikaci otevře a zobrazí oznámení s výsledkem. Pokud aplikace neběží, požadavek počká ve frontě a zpracuje se po spuštění aplikace. Složky a nečitelné soubory se přeskočí.

Ověřeno 30. 10. 2026: 32B testovací soubor odeslaný akcí se objevil na S25 jako `pcr-quickaction-test.txt` (stav `completed`, Wi‑Fi). Testovací soubor byl z telefonu smazán.

Adresa telefonu se ukládá v `transfers/settings.json` (pole „Adresa telefonu“ v kartě).
