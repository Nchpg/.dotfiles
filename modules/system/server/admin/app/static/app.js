// Comportements purement visuels ; tout ce qui compte (JSON, validation, diff) se fait côté serveur.

// Filtre de la liste des sites, réappliqué quand les cartes se rafraîchissent.
let filter = "all";
function applyFilter() {
  document.querySelectorAll("[data-filter]").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.filter === filter)));
  const keep = (vpn) => filter === "all" || (filter === "vpn") === vpn;
  document.querySelectorAll("table.sites tbody[data-vpn]").forEach((g) => {
    const rows = [...g.querySelectorAll("tr[data-row-vpn]")];
    // Service : une ligne, filtrée d'un bloc.
    if (!rows.length) {
      g.hidden = !keep(g.dataset.vpn === "true");
      return;
    }
    // Site : seuls ses environnements qui correspondent restent ; la cellule du nom (fusionnée sur
    // ses lignes) passe sur la première ligne visible, à la hauteur des lignes restantes.
    const shown = rows.filter((r) => keep(r.dataset.rowVpn === "true"));
    rows.forEach((r) => {
      r.hidden = !shown.includes(r);
      r.classList.toggle("first", r === shown[0]);
    });
    g.hidden = shown.length === 0;
    const cell = g.querySelector("td.site-td");
    if (cell && shown.length) {
      cell.rowSpan = shown.length;
      if (cell.parentElement !== shown[0]) shown[0].prepend(cell);
    }
  });
}
document.addEventListener("click", (ev) => {
  const btn = ev.target.closest?.("[data-filter]");
  if (!btn) return;
  filter = btn.dataset.filter;
  applyFilter();
});

// Exposition : appareils et suffixe d'adresse suivent le choix public / VPN.
document.addEventListener("change", (ev) => {
  const form = ev.target.closest?.("#site-form");
  if (!form || ev.target.name !== "expose") return;
  const vpn = ev.target.value === "vpn";
  form.querySelectorAll("[data-vpn-only]").forEach((el) => (el.hidden = !vpn));
  form.querySelectorAll("[data-public-only]").forEach((el) => (el.hidden = vpn));
  form.querySelectorAll("[data-suffix]").forEach((el) => (el.textContent = vpn ? el.dataset.vpn : el.dataset.public));
});

// Connexion Authelia : les comptes autorisés suivent la case.
document.addEventListener("change", (ev) => {
  const form = ev.target.closest?.("#site-form");
  if (!form || ev.target.name !== "sso") return;
  form.querySelectorAll("[data-sso-only]").forEach((el) => (el.hidden = !ev.target.checked));
});

// Choix du dépôt : filtre et sélection visibles (le formulaire arrive par htmx).
document.addEventListener("input", (ev) => {
  if (!ev.target.matches?.("[data-repo-filter]")) return;
  const q = ev.target.value.trim().toLowerCase();
  document.querySelectorAll(".repo").forEach((r) => (r.hidden = q !== "" && !r.dataset.name.includes(q)));
});
document.addEventListener("click", (ev) => {
  const repo = ev.target.closest?.(".repo");
  if (!repo) return;
  document.querySelectorAll(".repo").forEach((r) => r.setAttribute("aria-selected", String(r === repo)));
});

// Liens vers l'extérieur (sites, GitHub) : nouvel onglet ; la navigation du dashboard reste ici.
document.addEventListener("click", (ev) => {
  const a = ev.target.closest?.("a[href]");
  if (!a || a.host === location.host || !/^https?:$/.test(a.protocol)) return;
  a.target = "_blank";
  a.rel = "noopener noreferrer";
}, true);

// Après un rafraîchissement par htmx : filtre gardé, et rechargement demandé par le serveur
// (application réussie : la page repart des nouvelles valeurs, empreinte comprise).
document.addEventListener("htmx:afterSwap", () => {
  applyFilter();
  const r = document.querySelector("[data-reload-after]");
  if (r && !r.dataset.armed) {
    r.dataset.armed = "1";
    setTimeout(() => location.assign(r.dataset.reloadTo || location.href), Number(r.dataset.reloadAfter));
  }
});

// Listes déroulantes maison (icône par option) : la valeur va dans le champ caché, qui émet
// `change` comme un vrai champ (htmx s'en sert pour l'aperçu, ou pour refaire le formulaire).
function ddClose(dd, focus) {
  const list = dd.querySelector(".dd-list");
  if (!list || list.hidden) return;
  list.hidden = true;
  dd.querySelector(".dd-btn").setAttribute("aria-expanded", "false");
  if (focus) dd.querySelector(".dd-btn").focus();
}
function ddOpen(dd) {
  document.querySelectorAll("[data-dd]").forEach((o) => o !== dd && ddClose(o));
  const list = dd.querySelector(".dd-list");
  list.hidden = false;
  dd.querySelector(".dd-btn").setAttribute("aria-expanded", "true");
  (list.querySelector('[aria-selected="true"]') || list.querySelector("[role=option]"))?.focus();
}
function ddPick(dd, opt) {
  const input = dd.querySelector('input[type="hidden"]');
  dd.querySelectorAll("[role=option]").forEach((o) => o.setAttribute("aria-selected", String(o === opt)));
  const btn = dd.querySelector(".dd-btn");
  btn.querySelector(".dd-label").textContent = opt.dataset.label;
  btn.querySelector(".dd-label").classList.remove("muted");
  const ic = btn.querySelector(".dd-ic");
  ic.style.setProperty("--tint", opt.dataset.tint);
  ic.style.setProperty("--ink", opt.dataset.ink);
  ic.querySelector("path").setAttribute("d", opt.querySelector(".dd-ic path").getAttribute("d"));
  ddClose(dd, true);
  if (input.value === opt.dataset.value) return;
  input.value = opt.dataset.value;
  input.dispatchEvent(new Event("change", { bubbles: true }));
}
document.addEventListener("click", (ev) => {
  const btn = ev.target.closest(".dd-btn");
  const opt = ev.target.closest(".dd-list [role=option]");
  if (btn) {
    const dd = btn.closest("[data-dd]");
    dd.querySelector(".dd-list").hidden ? ddOpen(dd) : ddClose(dd, true);
  } else if (opt) {
    ddPick(opt.closest("[data-dd]"), opt);
  } else {
    document.querySelectorAll("[data-dd]").forEach((d) => ddClose(d));
  }
});
document.addEventListener("keydown", (ev) => {
  const dd = ev.target.closest?.("[data-dd]");
  if (!dd) return;
  const opts = [...dd.querySelectorAll("[role=option]")];
  const i = opts.indexOf(ev.target);
  if (ev.key === "Escape") { ddClose(dd, true); }
  else if (ev.key === "ArrowDown") { ev.preventDefault(); if (i < 0) ddOpen(dd); else opts[Math.min(i + 1, opts.length - 1)].focus(); }
  else if (ev.key === "ArrowUp") { ev.preventDefault(); if (i > 0) opts[i - 1].focus(); }
  else if ((ev.key === "Enter" || ev.key === " ") && i >= 0) { ev.preventDefault(); ddPick(dd, opts[i]); }
});

// Entrée dans un champ à bouton (dossier de données) : clique le bouton au lieu d'envoyer le formulaire.
document.addEventListener("keydown", (ev) => {
  if (ev.key !== "Enter" || !ev.target.matches?.("[data-enter-click]")) return;
  ev.preventDefault();
  ev.target.parentElement.querySelector("button")?.click();
});
// Le champ s'ouvre prêt à taper.
document.addEventListener("toggle", (ev) => {
  if (ev.target.matches && ev.target.matches(".data-adder") && ev.target.open) ev.target.querySelector("input")?.focus();
}, true);

// Navigation : une barre de chargement en haut dès le clic, le temps que la page suivante arrive.
document.addEventListener("click", (ev) => {
  const a = ev.target.closest?.("a[href]");
  if (!a || ev.defaultPrevented || ev.button !== 0 || ev.metaKey || ev.ctrlKey || ev.shiftKey || ev.altKey) return;
  if (a.target || a.hasAttribute("download") || a.origin !== location.origin || a.getAttribute("href").startsWith("#")) return;
  document.documentElement.classList.add("nav-loading");
});
// Retour arrière (page restaurée du cache) : pas de barre restée affichée.
addEventListener("pageshow", () => document.documentElement.classList.remove("nav-loading"));

// Bulles d'explication : une seule ouverte, fermée par un clic ailleurs.
document.addEventListener("click", (ev) => {
  document.querySelectorAll("details.info[open]").forEach((d) => {
    if (!d.contains(ev.target)) d.open = false;
  });
});
// Navigation par le menu (hx-boost, sans rechargement) : la barre s'arrête quand la page est en place.
for (const ev of ["htmx:afterSettle", "htmx:responseError", "htmx:sendError"]) {
  document.addEventListener(ev, () => document.documentElement.classList.remove("nav-loading"));
}

// Grafana (page Métriques) : l'iframe vit dans un calque hors du contenu, créé une fois et posé sur
// la place réservée de la page ; masqué ailleurs, il reste chargé et revient sans rechargement
// tant qu'on navigue par le menu.
function syncGrafana() {
  const pane = document.getElementById("grafana-pane");
  if (!pane) return;
  const slot = document.querySelector(".grafana-slot");
  if (!slot) {
    pane.hidden = true;
    return;
  }
  if (pane.dataset.src !== slot.dataset.grafanaSrc) {
    const frame = document.createElement("iframe");
    frame.src = slot.dataset.grafanaSrc;
    frame.title = slot.title;
    pane.replaceChildren(frame);
    pane.dataset.src = slot.dataset.grafanaSrc;
  }
  const r = slot.getBoundingClientRect();
  Object.assign(pane.style, { top: `${r.top}px`, left: `${r.left}px`, width: `${r.width}px`, height: `${r.height}px` });
  pane.hidden = false;
}
document.addEventListener("DOMContentLoaded", syncGrafana);
document.addEventListener("htmx:afterSettle", syncGrafana);
addEventListener("resize", syncGrafana);
addEventListener("scroll", syncGrafana, { passive: true });

// Bouton « Copier » des blocs de commande.
document.addEventListener("click", (ev) => {
  const btn = ev.target.closest?.("[data-copy]");
  if (!btn) return;
  const label = btn.textContent;
  navigator.clipboard?.writeText(btn.dataset.copy || btn.previousElementSibling.textContent).then(() => {
    btn.textContent = "Copié";
    setTimeout(() => (btn.textContent = label), 1500);
  });
});

// Voyant d'une demande : sur une page de liste, chaque changement d'état relit le contenu (les
// tableaux montrent alors le commit, puis ce que think applique), sans recharger la page.
document.addEventListener("htmx:beforeSwap", (ev) => {
  const old = ev.detail.target;
  if (!old.classList?.contains("track") || !("reload" in old.dataset)) return;
  const state = (ev.detail.serverResponse.match(/data-state="([a-z]+)"/) || [])[1];
  if (!state || state === old.dataset.state) return;
  setTimeout(() => htmx.ajax("GET", location.pathname + location.search, { target: ".content", select: ".content", swap: "outerHTML" }), 50);
});

// Navigation par le menu : la nouvelle page part du haut. htmx amènerait sinon le contenu en haut
// de l'écran (scrollIntoViewOnBoost, coupé dans layout.html), sous la barre du haut sur téléphone.
document.addEventListener("htmx:afterSwap", (ev) => {
  if (ev.detail.boosted || ev.detail.requestConfig?.boosted) window.scrollTo(0, 0);
});
