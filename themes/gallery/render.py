#!/usr/bin/env python3
"""Génère la galerie HTML des thèmes (commande `theme` sans argument).

Entrée  : un manifeste JSON { "<nom>": { path, source }, ... }, produit par
          themes/default.nix depuis `pathByName` — donc exactement
          les thèmes sélectionnables, ni plus ni moins.
Sortie  : un fichier HTML autonome (aucune ressource externe).

PyYAML plutôt que le parseur Nix de themes : celui-ci ne lit que ce
dont stylix a besoin, là où la galerie affiche aussi les slots base24 et les
métadonnées. Le rendu étant fait au build, un vrai parseur ne coûte rien.
"""

import html
import json
import sys

import yaml

SLOTS = [f"base0{c}" for c in "0123456789ABCDEF"]
# Slots propres à base24 : deux fonds plus sombres (base10/11) et six
# variantes « vives » des couleurs ANSI (base12-17). Absents d'un scheme
# base16, d'où le traitement optionnel partout.
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
        # base24 seulement si les 8 slots sont là : un scheme base16 qui en
        # déclarerait deux au hasard ne doit pas être annoncé comme base24.
        "extra": extra if len(extra) == len(SLOTS_BASE24) else {},
        # Repli sur "dark" : quelques schemes amont anciens ne déclarent pas
        # `variant`, et c'est la valeur par défaut de la spec base16.
        "variant": str(data.get("variant") or "dark"),
        "colors": colors,
    }


def card(key, scheme):
    c = scheme["colors"]
    esc = html.escape
    # Les data-* portent la recherche côté client (nom public, titre, auteur).
    haystack = f"{key} {scheme['name']} {scheme['author']}".lower()
    # Un thème clair remplace lightTheme, un sombre darkTheme : appliquer un
    # thème sombre à lightTheme donnerait une variante « claire » sombre.
    slot = "light" if scheme["variant"] == "light" else "dark"
    swatches = "".join(
        f'<i style="background:{c[s]}"></i>' for s in SLOTS
    )
    source = scheme.get("source", "upstream")
    extra = scheme.get("extra", {})
    is24 = bool(extra)

    # Slots base10-17 effectifs : un scheme base16 ne les déclare pas, mais
    # stylix les dérive (mkBase24 dans base16.nix). On affiche donc toujours
    # la rangée — elle montre ce que le terminal utilisera vraiment, met en
    # évidence que le base24 les distingue là où le base16 les recopie, et
    # aligne la hauteur des cartes.
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
    # Les 6 couleurs vives (base12-17) ET les 2 fonds sombres (base10/11) :
    # sans base10/11, la principale valeur ajoutée du base24 — des fonds plus
    # profonds que base00 — resterait invisible hors des pastilles.
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


CSS = """
:root { color-scheme: dark; }
* { box-sizing: border-box; }
/* Largeur partagée par l'en-tête et la grille. 2100px : 6 colonnes sur un
   écran 2K tout en gardant ~200px de marge de chaque côté. Le padding en
   clamp() garantit de l'air même sous le plafond. */
:root { --content: 2100px; }
body {
  margin: 0;
  padding: clamp(1rem, 2vw, 2rem) clamp(1rem, 3vw, 3rem) 4rem;
  background: #16181d; color: #d7dae0;
  font: 14px/1.5 ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
}
/* Collant : avec ~500 cartes, filtres et recherche doivent rester à portée
   sans remonter en haut de page. */
header.top {
  max-width: var(--content); margin: 0 auto 1.5rem;
  position: sticky; top: 0; z-index: 10;
  background: #16181d;
  padding-top: clamp(.5rem, 1.5vw, 1rem);
  padding-bottom: .9rem;
  box-shadow: 0 10px 18px -12px rgba(0,0,0,.9);
}
h1 { margin: 0 0 .35rem; font-size: 1.4rem; font-weight: 650; letter-spacing: -.01em; }
p.sub { margin: 0 0 1.25rem; color: #8b93a1; }
p.sub code {
  background: #22252c; padding: .1rem .35rem; border-radius: 4px;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .85em;
}
.controls { display: flex; gap: .6rem; flex-wrap: wrap; align-items: center; }
input[type=search] {
  flex: 1 1 260px; min-width: 0;
  padding: .55rem .8rem; border-radius: 8px;
  border: 1px solid #2c313a; background: #1c1f25; color: inherit; font: inherit;
}
input[type=search]:focus { outline: 2px solid #4d7ea8; outline-offset: -1px; }
.filters { display: flex; gap: .3rem; }
.filters button {
  padding: .55rem .9rem; border-radius: 8px; cursor: pointer;
  border: 1px solid #2c313a; background: #1c1f25; color: #8b93a1; font: inherit;
}
.filters button[aria-pressed=true] { background: #2c3440; color: #d7dae0; border-color: #3d454a; }
#done {
  padding: .55rem .9rem; border-radius: 8px; cursor: pointer; font: inherit;
  border: 1px solid #3f7a4a; background: #24352a; color: #b7e4c0;
}
#done:hover { background: #2d452f; }
#done:disabled { opacity: .5; cursor: default; }
body.static #done { display: none; }
.applied {
  margin: .9rem 0 0; padding: .6rem .8rem; border-radius: 8px;
  background: #1e2a20; border: 1px solid #2f5233; color: #b7e4c0;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12.5px;
}
.applied[hidden] { display: none; }
#count { color: #8b93a1; margin-left: auto; font-variant-numeric: tabular-nums; }
.grid {
  max-width: var(--content); margin: 0 auto;
  display: grid; gap: clamp(.75rem, 1vw, 1.15rem);
  /* auto-fill + minmax : le nombre de colonnes suit la largeur réelle
     (~4 en 1400px, ~7 en 2K) sans media query. */
  grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
}
.card {
  border: 1px solid #2c313a; border-radius: 10px; overflow: hidden;
  background: #1c1f25; display: flex; flex-direction: column;
}
.card[hidden] { display: none; }
/* Thèmes actuellement dans la config : remontés en tête de grille (order
   négatif) et fortement cerclés, pour les retrouver sans les chercher. */
.card.is-current {
  order: -2;
  border-color: #5aa9e6;
  box-shadow: 0 0 0 3px #5aa9e6, 0 0 18px rgba(90, 169, 230, .35);
}
.card.is-current footer { background: #1b2530; }
/* Favoris : remontés juste après les thèmes actifs (-1 contre -2), avec un
   liseré doré discret — repérable sans voler la vedette au thème courant. */
.card.is-favorite { order: -1; border-color: #7a6320; }
/* Actuelle ET favorite : à spécificité égale ce serait la dernière règle
   du fichier qui gagnerait, sortant la carte du groupe de tête. Ce
   sélecteur tranche pour « actuel », quel que soit l'ordre des règles. */
.card.is-current.is-favorite { order: -2; border-color: #5aa9e6; }
button.fav {
  flex: none; cursor: pointer; font: inherit; font-size: 15px; line-height: 1;
  padding: .15rem .35rem; border-radius: 5px;
  border: 1px solid transparent; background: transparent; color: #4d515a;
}
button.fav:hover { background: #262a32; color: #8b93a1; }
button.fav[aria-pressed=true] { color: #e8b93a; }
button.fav:disabled { opacity: .5; cursor: default; }
body.static button.fav { display: none; }
.current-tag {
  /* margin-left auto : sur une carte actuelle, le bouton « appliquer » est
     retiré (cf. syncApplyButtons) — sans ça la pastille viendrait se coller
     à l'étoile au lieu de rester à droite. */
  flex: none; margin-left: auto;
  font-size: 11px; font-weight: 650;
  text-transform: uppercase; letter-spacing: .05em;
  color: #06121d; background: #5aa9e6; border: 1px solid #5aa9e6;
  border-radius: 999px; padding: .12rem .55rem;
}
/* `hidden` est sans effet sur un élément dont le display est forcé par une
   autre règle : on le réaffirme pour les boutons du pied. */
footer button[hidden] { display: none; }
.preview { padding: 0; }
.chrome { display: flex; gap: .35rem; padding: .5rem .65rem; }
.chrome span { width: 10px; height: 10px; border-radius: 50%; display: block; }
/* Proche d'un vrai terminal : trop petit, le fond du thème occupe peu de
   surface et une palette claire paraît plus délavée qu'elle ne l'est. */
.preview pre {
  margin: 0; padding: 1rem 1.1rem 1.3rem;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 13px; line-height: 1.7; overflow-x: auto;
}
.swatches { display: flex; height: 22px; }
.swatches i { flex: 1; }
/* Rangée des 8 slots base10-17 : plus fine, pour se lire comme un
   complément et pas comme une seconde palette. */
/* JAMAIS d'opacity ni de filtre sur les pastilles : la galerie sert à juger
   des couleurs, toute retouche afficherait autre chose que ce que le
   terminal rendra. Le repère « dérivée vs déclarée » passe donc par le
   liseré au-dessus de la rangée — hors zone colorée — et par le badge
   base24. Liseré sur les DEUX (plein / tireté) pour que la hauteur reste
   identique entre base16 et base24. */
.swatches.extra { height: 12px; border-top: 1px solid rgba(255,255,255,.28); }
.swatches.extra.derived { border-top-style: dashed; border-top-color: rgba(255,255,255,.16); }
.spec {
  flex: none; font-size: 10.5px; font-weight: 650; letter-spacing: .04em;
  color: #d8c9a0; background: #3a3020; border: 1px solid #6b5a2e;
  border-radius: 999px; padding: .1rem .45rem;
}
footer {
  display: flex; align-items: center; gap: .5rem;
  padding: .6rem .7rem; border-top: 1px solid #2c313a;
}
/* Le nom occupe sa propre rangée : dans le pied, il était comprimé entre
   l'étoile, le bouton et les pastilles, illisible sur les noms longs. */
header.name {
  display: flex; align-items: center; gap: .4rem;
  padding: .5rem .6rem .45rem;
  border-bottom: 1px solid #2c313a;
}
button.copy {
  flex: 1; min-width: 0; text-align: left; cursor: pointer;
  background: transparent; border: 0; color: #d7dae0; font: inherit;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 13px;
  padding: .2rem .35rem; border-radius: 5px;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
button.copy:hover { background: #262a32; }
button.copy.copied { background: #2f5233; color: #b7e4c0; }
/* Les pastilles vivent dans l'en-tête : réunies ici avec l'étoile et le
   marqueur « actuel », elles ne laissaient qu'une trentaine de pixels au
   bouton sur une carte courante en base24. */
button.apply {
  flex: 1; min-width: 0; cursor: pointer; font: inherit; font-size: 11.5px;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
  padding: .2rem .55rem; border-radius: 5px;
  border: 1px solid #2c313a; background: #22262e; color: #9aa3b2;
}
button.apply:hover { background: #2c3440; color: #d7dae0; }
button.apply:disabled { opacity: .5; cursor: default; }
/* Sans serveur (page ouverte en file://), le bouton n'a rien à contacter. */
body.static button.apply { display: none; }
#toast {
  position: fixed; left: 50%; bottom: 1.5rem; transform: translateX(-50%);
  background: #22262e; border: 1px solid #3d454a; border-radius: 8px;
  padding: .7rem 1.1rem; max-width: min(90vw, 640px);
  box-shadow: 0 8px 24px rgba(0,0,0,.45);
}
#toast[hidden] { display: none; }
#toast.ok { border-color: #3f7a4a; }
#toast.err { border-color: #9a4b4b; color: #f0c0c0; }
.badge {
  flex: none; font-size: 11px; text-transform: uppercase; letter-spacing: .04em;
  color: #8b93a1; border: 1px solid #2c313a; border-radius: 999px; padding: .1rem .5rem;
}
.empty { max-width: var(--content); margin: 3rem auto; text-align: center; color: #8b93a1; }
.empty[hidden] { display: none; }

/* Sous ~600px (fenêtre étroite, pas seulement mobile) : les contrôles
   passent en pleine largeur plutôt que de se tasser sur une ligne. */
@media (max-width: 600px) {
  .controls { gap: .5rem; }
  input[type=search] { flex-basis: 100%; }
  .filters { flex: 1 1 auto; }
  .filters button { flex: 1; padding: .55rem .5rem; }
  #count { margin-left: 0; }
  header.top { position: static; }
}
"""

JS = """
// Jeton injecté par server.py au moment de servir la page. Reste au
// placeholder si la page est ouverte directement en file:// : dans ce cas il
// n'y a pas de serveur, et les boutons « appliquer » sont masqués (.static).
const TOKEN = '__THEME_TOKEN__';
if (TOKEN.startsWith('__')) document.body.classList.add('static');

// Thèmes actifs, injectés par le serveur : { dark: "...", light: "..." }.
// Reste au placeholder en file:// — d'où le try/catch, qui laisse un objet
// vide et donc aucune carte marquée.
let CURRENT = {};
try { CURRENT = JSON.parse('__THEME_CURRENT__'); } catch (err) { CURRENT = {}; }

// Favoris persistés dans gallery/favorites.json, injectés comme
// CURRENT. Même repli en file://.
let FAVORITES = new Set();
try { FAVORITES = new Set(JSON.parse('__THEME_FAVORITES__')); } catch (err) { FAVORITES = new Set(); }

const cardByName = new Map();

function markFavorites() {
  for (const [name, el] of cardByName) {
    const on = FAVORITES.has(name);
    el.classList.toggle('is-favorite', on);
    const btn = el.querySelector('button.fav');
    if (btn) {
      btn.setAttribute('aria-pressed', String(on));
      btn.title = on ? 'Retirer des favoris' : 'Mettre en favori';
    }
  }
}

function markCurrent() {
  for (const [name, el] of cardByName) {
    const tag = el.querySelector('.current-tag');
    if (tag) tag.remove();
    el.classList.remove('is-current');
  }
  for (const [slot, name] of Object.entries(CURRENT)) {
    const el = cardByName.get(name);
    if (!el) continue;
    el.classList.add('is-current');
    const tag = document.createElement('span');
    tag.className = 'current-tag';
    tag.textContent = 'actuel · ' + slot;
    el.querySelector('footer').append(tag);
  }
  syncApplyButtons();
}

// Un thème déjà en place n'a rien à appliquer : on RETIRE le bouton plutôt
// que de le griser — un bouton mort en permanence n'est que du bruit, la
// pastille « actuel · <slot> » dit déjà tout. La hauteur du pied ne bouge
// pas : c'est l'étoile, plus haute que le bouton, qui la détermine.
//
// La comparaison porte sur LE SLOT VISÉ par le bouton, pas sur « ce thème est
// quelque part dans CURRENT » : un thème sombre posé à la main dans
// lightTheme resterait légitimement applicable à darkTheme.
function syncApplyButtons() {
  for (const [name, el] of cardByName) {
    const btn = el.querySelector('button.apply');
    if (!btn) continue;
    const slot = btn.dataset.slot;
    btn.hidden = CURRENT[slot] === name;
    btn.disabled = false;
    btn.textContent = `appliquer dans ${slot}Theme`;
  }
}

const toast = document.getElementById('toast');
let toastTimer = null;
function showToast(message, kind) {
  toast.textContent = message;
  toast.className = kind;
  toast.hidden = false;
  clearTimeout(toastTimer);
  if (kind !== 'err') toastTimer = setTimeout(() => { toast.hidden = true; }, 6000);
}

const cards = Array.from(document.querySelectorAll('.card'));
for (const el of cards) {
  const btn = el.querySelector('button.apply') || el.querySelector('button.copy');
  if (btn) cardByName.set(btn.dataset.name, el);
}
markCurrent();
markFavorites();

const search = document.getElementById('search');
const count = document.getElementById('count');
const empty = document.getElementById('empty');
const filterButtons = Array.from(document.querySelectorAll('.filters button'));
// Un seul filtre actif à la fois : « custom » porte sur l'origine du thème,
// « dark »/« light » sur sa polarité — mutuellement exclusifs, comme les
// onglets d'une même liste.
let activeFilter = 'all';

function matchesFilter(card) {
  if (activeFilter === 'all') return true;
  if (activeFilter === 'custom') return card.dataset.source === 'custom';
  if (activeFilter === 'favorite') return card.classList.contains('is-favorite');
  return card.dataset.variant === activeFilter;
}

function apply() {
  const q = search.value.trim().toLowerCase();
  let shown = 0;
  for (const card of cards) {
    const okText = !q || card.dataset.search.includes(q);
    const visible = okText && matchesFilter(card);
    card.hidden = !visible;
    if (visible) shown++;
  }
  count.textContent = shown + ' / ' + cards.length;
  empty.hidden = shown !== 0;
}

search.addEventListener('input', apply);
for (const btn of filterButtons) {
  btn.addEventListener('click', () => {
    activeFilter = btn.dataset.filter;
    for (const b of filterButtons) b.setAttribute('aria-pressed', String(b === btn));
    apply();
  });
}

document.addEventListener('click', async (ev) => {
  const btn = ev.target.closest('button.copy');
  if (!btn) return;
  const name = btn.dataset.name;
  try {
    await navigator.clipboard.writeText(name);
  } catch (err) {
    // Clipboard API refusée (page file://, permission) : repli sur une
    // sélection temporaire, qui marche partout.
    const ta = document.createElement('textarea');
    ta.value = name;
    document.body.appendChild(ta);
    ta.select();
    document.execCommand('copy');
    ta.remove();
  }
  const previous = btn.textContent;
  btn.textContent = 'copié !';
  btn.classList.add('copied');
  setTimeout(() => { btn.textContent = previous; btn.classList.remove('copied'); }, 900);
});

// Slots déjà réglés dans cette session, pour le récapitulatif en haut de page.
const appliedBySlot = new Map();
const appliedBox = document.getElementById('applied');

function renderApplied() {
  if (appliedBySlot.size === 0) { appliedBox.hidden = true; return; }
  appliedBox.textContent =
    Array.from(appliedBySlot.values()).join('   ·   ') +
    '   — « terminer » pour revenir au terminal';
  appliedBox.hidden = false;
}

document.addEventListener('click', async (ev) => {
  const btn = ev.target.closest('button.apply');
  if (!btn) return;
  const name = btn.dataset.name;
  const slot = btn.dataset.slot;
  const label = btn.textContent;
  btn.disabled = true;
  btn.textContent = '…';
  try {
    const res = await fetch('/apply', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: TOKEN, name, slot }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || ('HTTP ' + res.status));
    appliedBySlot.set(slot, data.message);
    renderApplied();
    // Le marqueur « actuel » suit le choix : la carte remonte en tête,
    // l'ancienne perd son cerclage, et syncApplyButtons (appelé par
    // markCurrent) fixe l'état des DEUX boutons — celui-ci passe à « déjà
    // dans … » et l'ancien redevient applicable. D'où l'absence de
    // restauration manuelle du libellé ici : elle écraserait ce calcul.
    CURRENT[slot] = name;
    markCurrent();
    showToast(data.message, 'ok');
  } catch (err) {
    showToast('Échec : ' + err.message, 'err');
    btn.textContent = label;
    btn.disabled = false;
  }
});

document.addEventListener('click', async (ev) => {
  const btn = ev.target.closest('button.fav');
  if (!btn) return;
  const name = btn.dataset.name;
  const on = !FAVORITES.has(name);
  btn.disabled = true;
  try {
    const res = await fetch('/favorite', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: TOKEN, name, on }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || ('HTTP ' + res.status));
    // On repart de la liste renvoyée par le serveur, pas d'un état deviné
    // côté client : le fichier reste la source de vérité.
    FAVORITES = new Set(data.favorites);
    markFavorites();
    // Le filtre « favoris » doit refléter le retrait immédiatement.
    if (activeFilter === 'favorite') apply();
  } catch (err) {
    showToast('Favori : ' + err.message, 'err');
  }
  btn.disabled = false;
});

const doneBtn = document.getElementById('done');
doneBtn.addEventListener('click', async () => {
  doneBtn.disabled = true;
  doneBtn.textContent = '…';
  try {
    await fetch('/session', {
      method: 'DELETE',
      headers: { 'X-Theme-Token': TOKEN },
    });
  } catch (err) {
    // Le serveur coupe la connexion en répondant : une erreur réseau ici
    // signifie généralement qu'il s'est bien arrêté.
  }
  doneBtn.textContent = 'terminé';
  showToast('Session terminée — la suite se passe dans le terminal. Tu peux fermer cet onglet.', 'ok');
  for (const b of document.querySelectorAll('button.apply')) b.disabled = true;
});

apply();
// preventScroll : sans ça, focus() fait défiler la page pour « amener le
// champ dans la vue » — et comme l'en-tête est en position:sticky, le
// navigateur sur-corrige et on arrive sous le titre au lieu du haut de page.
search.focus({ preventScroll: true });
"""


def main():
    manifest_path, out_path = sys.argv[1], sys.argv[2]
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
<style>{CSS}</style>
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
<script>{JS}</script>
</body>
</html>
"""
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(doc)


if __name__ == "__main__":
    main()
