#!/bin/zsh
# Sestaví balík webu Pure Clipboard pro nahrání na server (nic nenahrává).
# Výstup: dist/web-bundle/ (struktura pro studiopuresound.cz) a dist/pure-clipboard-web-bundle.zip.
# Kontroly před zabalením: žádný zástupný text {{…}}, žádný odkaz na DMG, kanonické adresy odpovídají cílové struktuře.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/web/pure-clipboard"
OUT="$ROOT/dist/web-bundle"
ZIP="$ROOT/dist/pure-clipboard-web-bundle.zip"

rm -rf "$OUT" "$ZIP"
mkdir -p "$OUT/cs/lab/pure-clipboard" "$OUT/en/lab/pure-clipboard" "$OUT/assets/pure-clipboard"
cp "$SRC/assets/"* "$OUT/assets/pure-clipboard/"

python3 - "$SRC" "$OUT" <<'PY'
import pathlib, sys
src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
rewrites = [
    ("../assets/", "/assets/pure-clipboard/"),
    ("https://www.studiopuresound.cz/assets/pure-clipboard-og.png",
     "https://www.studiopuresound.cz/assets/pure-clipboard/pure-clipboard-og.png"),
]
for lang in ("cs", "en"):
    html = (src / lang / "index.html").read_text(encoding="utf-8")
    for a, b in rewrites:
        html = html.replace(a, b)
    import re
    if re.search(r"\{\{[A-Z_]+\}\}", html):
        sys.exit(f"{lang}: zůstal zástupný text ve tvaru {{{{NAZEV}}}}")
    if '.dmg"' in html:
        sys.exit(f"{lang}: stránka odkazuje na DMG – před finálním vydáním nepovoleno")
    expected = f"https://www.studiopuresound.cz/{lang}/lab/pure-clipboard/"
    if f'rel="canonical" href="{expected}"' not in html:
        sys.exit(f"{lang}: kanonická adresa neodpovídá {expected}")
    (out / lang / "lab" / "pure-clipboard" / "index.html").write_text(html, encoding="utf-8")
print("kontroly HTML OK")
PY

(cd "$ROOT/dist" && zip -qr "$ZIP" web-bundle)
echo "Balík: $OUT"
echo "ZIP:   $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "NIC NENAHRÁNO. Nasazení vyžaduje výslovný souhlas vlastníka."
