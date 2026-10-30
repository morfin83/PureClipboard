#!/usr/bin/env python3
"""Builds cs/index.html and en/index.html from content/pure-clipboard.{cs,en}.json.
Run from web/pure-clipboard:  python3 source/build-pages.py"""
import html, json, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
e = html.escape

def page(c):
    img = {i["file"]: i for i in c["images"]}
    hero = img["assets/app-preview.png"]
    ld = {"@context": "https://schema.org", "@type": "SoftwareApplication", "name": "Pure Clipboard",
          "applicationCategory": "UtilitiesApplication", "operatingSystem": "macOS 14+ (Apple Silicon)",
          "description": c["seo"]["description"], "softwareVersion": "0.7.0", "inLanguage": c["lang"],
          "publisher": {"@type": "Organization", "name": "PURE"}}
    other = "en" if c["lang"] == "cs" else "cs"
    faq_ld = {"@context": "https://schema.org", "@type": "FAQPage", "mainEntity": [
        {"@type": "Question", "name": f["q"], "acceptedAnswer": {"@type": "Answer", "text": f["a"]}} for f in c["faq"]]}
    shots = "".join(f'<figure><img src="../{i["file"]}" alt="{e(i["alt"])}" loading="lazy"><figcaption>{e(i["caption"])}</figcaption></figure>'
                    for i in [i for i in c["images"] if i["file"] not in ("assets/app-preview.png","assets/hero-preview.png")])
    feats = "".join(f'<div><h3>{e(f["title"])}</h3><p>{e(f["text"])}</p></div>' for f in c["features"])
    faq = "".join(f'<details><summary>{e(f["q"])}</summary><p>{e(f["a"])}</p></details>' for f in c["faq"])
    log = "".join(f'<h3>v{e(l["version"])}<time>{e(l["date"])}</time></h3><ul class="plain">' + "".join(f"<li>{e(i)}</li>" for i in l["items"]) + "</ul>" for l in c["changelog"])
    return f'''<!doctype html>
<html lang="{c["lang"]}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{e(c["seo"]["title"])}</title>
<meta name="description" content="{e(c["seo"]["description"])}">
<meta name="theme-color" content="#fafaf8">
<link rel="canonical" href="{c["url"]}">
<link rel="alternate" hreflang="{c["lang"]}" href="{c["url"]}">
<link rel="alternate" hreflang="{other}" href="{c["alternate"]}">
<link rel="icon" type="image/png" href="../assets/favicon-64.png">
<link rel="apple-touch-icon" href="../assets/apple-touch-icon.png">
<meta property="og:type" content="website">
<meta property="og:title" content="{e(c["seo"]["ogTitle"])}">
<meta property="og:description" content="{e(c["seo"]["ogDescription"])}">
<meta property="og:url" content="{c["url"]}">
<meta property="og:locale" content="{c["locale"]}">
<meta property="og:image" content="https://www.studiopuresound.cz/assets/pure-clipboard-og.png">
<meta property="og:image:alt" content="{e(c["seo"]["ogImageAlt"])}">
<meta name="twitter:card" content="summary_large_image">
<link rel="stylesheet" href="../assets/pure-clipboard.css">
<script type="application/ld+json">{json.dumps(ld, ensure_ascii=False)}</script>
<script type="application/ld+json">{json.dumps(faq_ld, ensure_ascii=False)}</script>
</head>
<body>
<a class="skip" href="#main">{"Přeskočit na obsah" if c["lang"]=="cs" else "Skip to content"}</a>
<div class="wrap">
<header class="top"><a href="../">{e(c["backLabel"])}</a><a href="{c["alternate"]}" hreflang="{other}">{other.upper()}</a></header>
<main id="main">
<div class="hero">
<div>
<p class="eyebrow">{e(c["hero"]["eyebrow"])}</p>
<h1>{e(c["hero"]["title"])}</h1>
<p class="tagline">{e(c["hero"]["tagline"])}</p>
<!-- No working download link until the Developer ID signed and notarized DMG exists (see HANDOFF-CODEX.md). -->
<span class="cta" role="note" aria-disabled="true">{e(c["hero"]["downloadLabel"])}</span><span class="status">{e(c["hero"]["status"])}</span>
<p class="note">{e(c["hero"]["downloadNote"])}</p>
</div>
<figure class="preview"><img src="../{hero["file"]}" alt="{e(hero["alt"])}" width="1520" height="1900"><figcaption style="padding:10px 16px;color:#a3a49d">{e(c["heroCaption"])}</figcaption></figure>
</div>
<section><p class="intro">{e(c["intro"])}</p></section>
<section><h2>{e(c["featuresTitle"])}</h2><div class="grid">{feats}</div></section>
<section><h2>{e(c["privacyTitle"])}</h2><ul class="plain">{"".join(f"<li>{e(p)}</li>" for p in c["privacy"])}</ul></section>
<section><div class="shots">{shots}</div></section>
<section><h2>{e(c["requirementsTitle"])}</h2><ul class="plain">{"".join(f"<li>{e(r)}</li>" for r in c["requirements"])}</ul></section>
<section><h2>{e(c["installTitle"])}</h2><p class="intro">{e(c["installIntro"])}</p><ol class="plain">{"".join(f"<li>{e(s)}</li>" for s in c["install"])}</ol><p class="note">{e(c["installNote"])}</p></section>
<section><h2>{e(c["faqTitle"])}</h2>{faq}</section>
<section class="log"><h2>{e(c["changelogTitle"])}</h2>{log}</section>
</main>
<footer>{e(c["footer"])}</footer>
</div>
</body>
</html>
'''

for lang in ("cs", "en"):
    c = json.load(open(root / "content" / f"pure-clipboard.{lang}.json"))
    out = root / lang
    out.mkdir(exist_ok=True)
    (out / "index.html").write_text(page(c), encoding="utf-8")
    print("built", out / "index.html")
