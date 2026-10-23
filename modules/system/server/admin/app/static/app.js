// Comportements purement visuels ; tout ce qui compte (JSON, validation, diff) se fait côté serveur.

// Filtre de la liste des sites, réappliqué quand les cartes se rafraîchissent.
let filter = "all";
function applyFilter() {
  document.querySelectorAll("[data-filter]").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.filter === filter)));
  // Un site reste groupé : visible dès qu'un de ses environnements correspond au filtre.
  document.querySelectorAll("table.sites tbody[data-vpn]").forEach((g) => {
    g.hidden = (filter === "vpn" ? g.dataset.vpn !== "true" : filter === "public" ? g.dataset.public !== "true" : false);
  });
}
document.addEventListener("click", (ev) => {
  const btn = ev.target.closest && ev.target.closest("[data-filter]");
  if (!btn) return;
  filter = btn.dataset.filter;
  applyFilter();
});

// Exposition : appareils et suffixe d'adresse suivent le choix public / VPN.
document.addEventListener("change", (ev) => {
  const form = ev.target.closest && ev.target.closest("#site-form");
  if (!form || ev.target.name !== "expose") return;
  const vpn = ev.target.value === "vpn";
  form.querySelectorAll("[data-vpn-only]").forEach((el) => (el.hidden = !vpn));
  form.querySelectorAll("[data-public-only]").forEach((el) => (el.hidden = vpn));
  form.querySelectorAll("[data-suffix]").forEach((el) => (el.textContent = vpn ? el.dataset.vpn : el.dataset.public));
});

// Choix du dépôt : filtre et sélection visibles (le formulaire arrive par htmx).
document.addEventListener("input", (ev) => {
  if (!ev.target.matches || !ev.target.matches("[data-repo-filter]")) return;
  const q = ev.target.value.trim().toLowerCase();
  document.querySelectorAll(".repo").forEach((r) => (r.hidden = q !== "" && !r.dataset.name.includes(q)));
});
document.addEventListener("click", (ev) => {
  const repo = ev.target.closest && ev.target.closest(".repo");
  if (!repo) return;
  document.querySelectorAll(".repo").forEach((r) => r.setAttribute("aria-selected", String(r === repo)));
});

// Liens vers l'extérieur (sites, GitHub) : nouvel onglet ; la navigation du dashboard reste ici.
document.addEventListener("click", (ev) => {
  const a = ev.target.closest && ev.target.closest("a[href]");
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
  const t = ev.target.closest ? ev.target : null;
  const btn = t && t.closest(".dd-btn");
  const opt = t && t.closest(".dd-list [role=option]");
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
  const dd = ev.target.closest && ev.target.closest("[data-dd]");
  if (!dd) return;
  const opts = [...dd.querySelectorAll("[role=option]")];
  const i = opts.indexOf(ev.target);
  if (ev.key === "Escape") { ddClose(dd, true); }
  else if (ev.key === "ArrowDown") { ev.preventDefault(); if (i < 0) ddOpen(dd); else opts[Math.min(i + 1, opts.length - 1)].focus(); }
  else if (ev.key === "ArrowUp") { ev.preventDefault(); if (i > 0) opts[i - 1].focus(); }
  else if ((ev.key === "Enter" || ev.key === " ") && i >= 0) { ev.preventDefault(); ddPick(dd, opts[i]); }
  else return;
});

// Entrée dans un champ à bouton (dossier de données) : clique le bouton au lieu d'envoyer le formulaire.
document.addEventListener("keydown", (ev) => {
  if (ev.key !== "Enter" || !ev.target.matches || !ev.target.matches("[data-enter-click]")) return;
  ev.preventDefault();
  ev.target.parentElement.querySelector("button")?.click();
});
// Le champ s'ouvre prêt à taper.
document.addEventListener("toggle", (ev) => {
  if (ev.target.matches && ev.target.matches(".data-adder") && ev.target.open) ev.target.querySelector("input")?.focus();
}, true);

// Navigation : une barre de chargement en haut dès le clic, le temps que la page suivante arrive.
document.addEventListener("click", (ev) => {
  const a = ev.target.closest && ev.target.closest("a[href]");
  if (!a || ev.defaultPrevented || ev.button !== 0 || ev.metaKey || ev.ctrlKey || ev.shiftKey || ev.altKey) return;
  if (a.target || a.hasAttribute("download") || a.origin !== location.origin || a.getAttribute("href").startsWith("#")) return;
  document.documentElement.classList.add("nav-loading");
});
// Retour arrière (page restaurée du cache) : pas de barre restée affichée.
addEventListener("pageshow", () => document.documentElement.classList.remove("nav-loading"));
