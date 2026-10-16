#!/usr/bin/env python3
"""Génère la galerie HTML des thèmes à partir du manifeste JSON."""

import html
import json
import sys

import yaml

SLOTS = [f"base0{c}" for c in "0123456789ABCDEF"]
SLOTS_BASE24 = [f"base1{c}" for c in "01234567"]


def load_scheme(path):
    with open(path, encoding="utf-8") as fh:
        data = yaml.safe_load(fh)

    palette = data.get("palette", {})
    colors = {}
    for slot in SLOTS:
        value = palette.get(slot)
        if value is None:
            return None
        colors[slot] = "#" + str(value).lstrip("#").lower()

    extra = {}
    for slot in SLOTS_BASE24:
        value = palette.get(slot)
        if value is not None:
            extra[slot] = "#" + str(value).lstrip("#").lower()

    return {
        "name": str(data.get("name") or "untitled"),
        "author": str(data.get("author") or ""),
        "extra": extra if len(extra) == len(SLOTS_BASE24) else {},
        "variant": str(data.get("variant") or "dark"),
        "colors": colors,
    }


def card(key, scheme):
    c = scheme["colors"]
    esc = html.escape
    haystack = f"{key} {scheme['name']} {scheme['author']}".lower()
    slot = "light" if scheme["variant"] == "light" else "dark"
    swatches = "".join(
        f'<i style="background:{c[s]}"></i>' for s in SLOTS
    )
    source = scheme.get("source", "upstream")
    extra = scheme.get("extra", {})
    is24 = bool(extra)

    # Slots base10-17 effectifs : stylix les dérive pour un scheme base16.
    eff = extra or {
        "base10": c["base00"], "base11": c["base00"],
        "base12": c["base08"], "base13": c["base0A"],
        "base14": c["base0B"], "base15": c["base0C"],
        "base16": c["base0D"], "base17": c["base0E"],
    }
    row_title = (
        "base10-base17 (déclarées par le scheme base24)"
        if is24
        else "base10-base17 dérivées : un scheme base16 réutilise ses couleurs normales"
    )
    extra_swatches = (
        f'<div class="swatches extra{"" if is24 else " derived"}" title="{esc(row_title)}">'
        + "".join(f'<i style="background:{eff[s]}"></i>' for s in SLOTS_BASE24)
        + "</div>"
    )
    bright_line = f"""
<span style="background:{eff['base11']};color:{c['base05']}"> vifs </span><span style="background:{eff['base10']};color:{eff['base12']}"> ●</span><span style="background:{eff['base10']};color:{eff['base13']}">●</span><span style="background:{eff['base10']};color:{eff['base14']}">●</span><span style="background:{eff['base10']};color:{eff['base15']}">●</span><span style="background:{eff['base10']};color:{eff['base16']}">●</span><span style="background:{eff['base10']};color:{eff['base17']}">● </span>"""
    spec_badge = '<span class="spec">base24</span>' if is24 else ""
    return f"""
<article class="card" data-search="{esc(haystack)}" data-variant="{esc(scheme['variant'])}"
         data-source="{esc(source)}">
  <header class="name">
    <button class="copy" data-name="{esc(key)}" title="Copier le nom">{esc(key)}</button>
    {spec_badge}<span class="badge">{esc(scheme['variant'])}</span>
  </header>
  <div class="preview" style="background:{c['base00']};color:{c['base05']}">
    <div class="chrome" style="background:{c['base01']}">
      <span style="background:{c['base08']}"></span>
      <span style="background:{c['base0A']}"></span>
      <span style="background:{c['base0B']}"></span>
    </div>
    <pre><code><span style="color:{c['base03']}"># {esc(scheme['name'])}</span>
<span style="color:{c['base0E']}">let</span> <span style="color:{c['base0D']}">palette</span> <span style="color:{c['base05']}">=</span> {{
  <span style="color:{c['base0D']}">background</span> <span style="color:{c['base05']}">=</span> <span style="color:{c['base0B']}">"{c['base00']}"</span>;
  <span style="color:{c['base0D']}">foreground</span> <span style="color:{c['base05']}">=</span> <span style="color:{c['base0B']}">"{c['base05']}"</span>;
  <span style="color:{c['base0D']}">accent</span>     <span style="color:{c['base05']}">=</span> <span style="color:{c['base0B']}">"{c['base0D']}"</span>;
  <span style="color:{c['base0D']}">count</span>      <span style="color:{c['base05']}">=</span> <span style="color:{c['base09']}">42</span>;
}};

<span style="color:{c['base03']}">$</span> <span style="color:{c['base0B']}">git</span> status
<span style="color:{c['base08']}">-  supprimé</span>
<span style="color:{c['base0B']}">+  ajouté</span>
<span style="color:{c['base0A']}">?  non suivi</span>{bright_line}</code></pre>
    <div class="swatches">{swatches}</div>
    {extra_swatches}
  </div>
  <footer>
    <button class="fav" data-name="{esc(key)}" aria-pressed="false"
            title="Mettre en favori">★</button>
    <button class="apply" data-name="{esc(key)}" data-slot="{esc(slot)}"
            title="Remplacer {esc(slot)}Theme dans la config">appliquer dans {esc(slot)}Theme</button>
  </footer>
</article>"""


def main():
    manifest_path, out_path, css_path, js_path = sys.argv[1:5]
    with open(css_path, encoding="utf-8") as fh:
        css = fh.read()
    with open(js_path, encoding="utf-8") as fh:
        js = fh.read()
    with open(manifest_path, encoding="utf-8") as fh:
        manifest = json.load(fh)

    schemes = {}
    skipped = []
    for key in sorted(manifest):
        entry = manifest[key]
        scheme = load_scheme(entry["path"])
        if scheme is None:
            skipped.append(key)
            continue
        scheme["source"] = entry.get("source", "upstream")
        schemes[key] = scheme

    if skipped:
        print(
            f"gallery: {len(skipped)} thème(s) sans palette complète, ignoré(s) : "
            + ", ".join(skipped),
            file=sys.stderr,
        )

    cards = "\n".join(card(k, s) for k, s in schemes.items())
    doc = f"""<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Thèmes disponibles ({len(schemes)})</title>
<style>
{css}</style>
</head>
<body>
<header class="top">
  <h1>Thèmes disponibles</h1>
  <p class="sub">
    <strong>appliquer</strong> remplace <code>darkTheme</code> (thèmes sombres)
    ou <code>lightTheme</code> (thèmes clairs) dans le profil. Tu peux en régler
    plusieurs — un sombre et un clair — puis <strong>terminer</strong> pour
    revenir au terminal et rebuilder. Cliquer le <em>nom</em> le copie simplement.
  </p>
  <div class="controls">
    <input id="search" type="search" placeholder="Filtrer par nom ou auteur…" autocomplete="off">
    <div class="filters">
      <button data-filter="all" aria-pressed="true">Tous</button>
      <button data-filter="favorite" aria-pressed="false">★ Favoris</button>
      <button data-filter="custom" aria-pressed="false">Custom</button>
      <button data-filter="dark" aria-pressed="false">Sombres</button>
      <button data-filter="light" aria-pressed="false">Clairs</button>
    </div>
    <button id="done" type="button">terminer</button>
    <span id="count"></span>
  </div>
  <p class="applied" id="applied" hidden></p>
</header>
<main class="grid">
{cards}
</main>
<p class="empty" id="empty" hidden>Aucun thème ne correspond.</p>
<div id="toast" hidden></div>
<script>
{js}</script>
</body>
</html>
"""
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(doc)


if __name__ == "__main__":
    main()
