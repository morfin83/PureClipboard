> **Aktuální verze webových podkladů je v `web/pure-clipboard/` (CS+EN, grafika, předávací dokument pro Codex).** Tento soubor je starší textový koncept; tlačítko ke stažení nepublikovat před finálním Developer ID DMG.

# Texty pro veřejnou stránku Pure Clipboard (web PureStudio)

Hotové české texty k vložení na stránku. Hodnoty ve složených závorkách (`{{…}}`) se doplní při vydání. Texty nic neslibují, co aplikace neumí (viz „Co nepsat“ na konci).

---

## Metadata stránky

- **Titulek (SEO):** Pure Clipboard – kopírování odpovědí AI na Macu | PureStudio
- **Popis (SEO, ≤ 155 znaků):** Pure Clipboard pro Mac: bezpečné kopírování odpovědí z Claude Code, Codexu a Terminálu. Bez internetu, bez sledování, s ochranou hesel.
- **Adresa:** `/pure-clipboard`
- **Náhledový obrázek:** `docs/assets/AppIcon-1024.png`

---

## Hlavička (hero)

**Pure Clipboard**
*Odpovědi AI ve schránce přesně tehdy, když je chcete.*

Pure Clipboard je malá nativní aplikace pro Mac. Pomáhá přenášet odpovědi mezi AI nástroji, kopíruje je na váš pokyn nebo (volitelně) hned po dokončení a hlídá, aby se do schránky nedostala hesla a tokeny.

**[Stáhnout verzi {{VERZE}} pro Mac (Apple Silicon)]** · SHA-256: `{{SHA256}}` · [Návod k instalaci](#instalace)

*macOS 14 nebo novější, čip Apple (M1 a novější).*

---

## Co umí

### Ruční přenos bez starostí
Označte text v ChatGPT, Claude, Gemini nebo Terminálu, stiskněte `⌘C`, přepněte se `⌘Tab` a vložte `⌘V`. Pure Clipboard do toho nezasahuje a nečte vaši schránku, dokud sami nezapnete volitelnou historii. Nastavení a ochranu spravujete na jednom místě.

### Samočinné kopírování z Claude Code a Codexu
Po dokončení odpovědi může Pure Clipboard její finální text zkopírovat za vás. Funguje přes oficiální hooky obou nástrojů, nikoli čtením obrazovky nebo odposlechem kláves. Zapnete ho přepínačem **Auto Copy** a každá integrace se instaluje jen po zobrazení plánu změn a se zálohou.

### Výstup příkazů z Terminálu
Napište `pclip` před libovolný příkaz (`pclip swift build`). Příkaz proběhne jako obvykle, vrátí stejný kód a jeho výstup se zkopíruje; při chybě s řádkem `[exit N]`.

### Ochrana citlivých údajů
Než se cokoli zkopíruje samo, projde text kontrolou: soukromé klíče, tokeny (GitHub, Slack, Stripe…), JWT, hesla v přiřazeních, adresy s přihlašovacími údaji i dlouhé náhodné řetězce. Při jakékoli pochybnosti se nekopíruje.

### Více agentů najednou
Když skončí několik relací současně, jedna druhou nepřepíše: schránku drží ta, která kopírovala první, a ostatní se bezpečně přeskočí.

### Termux: text mezi telefonem a Macem
Pošlete text z Termuxu na Androidu do Macu příkazem `pcr tomac` a naopak `pcr frommac`. Přenos běží jen na váš příkaz, přes váš vlastní SSH klíč a Tailscale. Přijatý text počká v aplikaci a do schránky ho dáte sami tlačítkem Kopírovat. Citlivé údaje se nepřenášejí. (Vyžaduje Termux, Termux:API a Tailscale; zatím nevyzkoušeno na všech telefonech.)

### Pure Remote: přehled spojení Tailscale
(Vyžaduje nainstalovaný Tailscale.) Živý přehled zařízení ve vaší síti Tailscale a rychlosti odesílání a příjmu mezi tímto Macem a každým zařízením. Čte pouze místní stav, nic nenastavuje a nic neukládá.

---

## Jak to funguje (tři kroky)

1. **Nainstalujte** aplikaci přetažením do složky Applications.
2. **Zapněte**, co chcete: Auto Copy, Claude Code, Codex nebo `pclip`. Aplikace vždy ukáže, co se změní.
3. **Pracujte jako dřív.** Zkopírované texty najdete ve schránce; v kartě každé integrace je řádek „Poslední událost“.

---

## Soukromí a bezpečnost

- **Žádný internet.** Aplikace nenavazuje síťová spojení, neposílá statistiky ani chybová hlášení.
- **Žádné sledování schránky.** Nečte schránku ostatních aplikací ani obrazovku, neodposlouchává klávesnici.
- **Obsah se neukládá.** Zapisují se jen metadata poslední události (čas, výsledek, počet znaků). Výjimky: `pclip` (výstup příkazu se na okamžik uloží do dočasného souboru čitelného jen vámi a po dokončení se smaže) a Termux (text čekající v přijaté nebo odesílané poště, v soukromé složce, nejdéle hodinu).
- **Vaše nastavení zůstává vaše.** Změny v cizích souborech (`~/.claude`, `~/.codex`, `~/.zshrc`) se dělají jen po potvrzení, se zálohou a jdou přesně vrátit zpět.
- **Bez administrátorských oprávnění**, bez služeb běžících na pozadí.

## Systémové požadavky

- Mac s čipem Apple (M1 nebo novější), macOS 14 nebo novější (vyzkoušeno na macOS 27).
- Macy s Intelem zatím nejsou podporované.
- Claude Code a/nebo Codex CLI jen pokud chcete jejich samočinné kopírování. Codex Desktop zatím nebyl ověřen.

---

## <a id="instalace"></a>Instalace

1. Stáhněte `.dmg` a ověřte SHA-256 (`shasum -a 256 soubor.dmg`).
2. Otevřete jej a přetáhněte **Pure Clipboard** do **Applications**.
3. Při prvním spuštění macOS aplikaci zablokuje, protože zatím není notarizovaná Applem. Povolíte ji v **Nastavení systému → Soukromí a zabezpečení → Přesto otevřít**.

Podrobný návod pro začátečníky: [Návod k instalaci](INSTALACE.md).

### Poctivě o podpisu
Aplikace je podepsaná pouze **ad-hoc podpisem**, který zaručuje celistvost balíčku, ale **není náhradou za notarizaci Applem**. Proto se při prvním spuštění zobrazí upozornění macOS. Podpis Developer ID a notarizace jsou v plánu; odstraní upozornění, ale na funkci ani soukromí nic nemění.

---

## Časté otázky

**Čte Pure Clipboard všechno, co kopíruji?**
Ne. Nečte schránku ostatních aplikací. Pracuje jen s odpověďmi z Claude Code a Codexu (pokud to zapnete) a s výstupem příkazů, které spustíte přes `pclip`.

**Mohou se do schránky dostat moje hesla?**
Automatické kopírování a `pclip` kontrolují text na hesla, tokeny a klíče a při podezření nekopírují. Kontrola je záměrně přísná, takže občas zastaví i neškodný text. Ruční `⌘C` v jiných aplikacích řídí macOS a Pure Clipboard do něj nezasahuje.

**Musím mít Claude Code nebo Codex?**
Ne. Bez nich zůstává ruční přenos, `pclip` a Pure Remote.

**Proč Codex nekopíruje hned po instalaci?**
Codex nový hook musí nejdřív schválit uživatel. V Codexu zadejte `/hooks` a hook potvrďte.

**Proč mi macOS aplikaci blokuje?**
Aplikace zatím není notarizovaná. Postup povolení je v návodu k instalaci.

**Jak aplikaci úplně odstraním?**
V aplikaci u každé integrace klikněte na **Odebrat**, potom přesuňte aplikaci do koše. Volitelně smažte `~/Library/Application Support/PureClipboard` (zálohy).

**Sleduje Pure Clipboard moji schránku?**
Jen když výslovně zapnete historii schránky (výchozí je vypnuto) a jen dokud je aplikace spuštěná. Vše zůstává na vašem Macu.

**Bude i pro Windows nebo Android?**
Plánujeme samostatné aplikace pro Windows 11 a Android a přenos textu mezi zařízeními. Zatím nejsou k dispozici.

**Je historie schránky?**
Zatím ne. Nastavení limitu je připravené, funkce se připravuje.

---

## Novinky

- **0.6.0** – Termux: přenos textu mezi S25 a Macem na výslovný příkaz.
- **0.5.0** – Pure Remote: přehled spojení Tailscale; nová ikona; příprava distribuce.
- **0.4.0** – Ruční kopírování jako hlavní způsob; `pclip` funguje i s vypnutým Auto Copy.
- **0.3.0** – Apple Terminal (`pclip`), souběh více agentů bez přepisování schránky, Codex.
- **0.2.0** – Samočinné kopírování z Claude Code.
- **0.1.0** – První verze: okno, bezpečné nastavení a ochrana citlivých údajů.

---

## Patička

© 2026 PureStudio · [Návod k instalaci](INSTALACE.md) · Podpora: {{KONTAKT}}

---

## Co nepsat (nepravdivá nebo neověřená tvrzení)

- že je aplikace **notarizovaná** nebo „ověřená Applem“;
- že podporuje **Intel**, **Windows**, **Android** nebo **Codex Desktop**;
- že historie je „vždy zapnutá“ nebo že ochrana citlivých údajů v obrázcích je spolehlivá;
- že „zabrání všem únikům“: ochrana je heuristická a platí jen pro automatické kopírování a `pclip`;
- že automaticky kopíruje „všechno“ z Terminálu: kopíruje se jen příkaz spuštěný přes `pclip`;
- že se aktualizuje samo (zatím ne);
- že Termux funguje na každém telefonu nebo „sám sleduje schránku telefonu“: jen výslovné příkazy `pcr`, vyžaduje Termux, `openssh`, `termux-api`, aplikaci Termux:API, Tailscale a SSH klíč; ověřeno simulací, ne na všech zařízeních.
