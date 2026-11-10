// Comportements purement visuels ; tout ce qui compte (JSON, validation, diff) se fait côté serveur.
//
// Comportement global de htmx (rien à écrire dans les templates) :
// - navigation : les liens du menu et du contenu changent le contenu seul (hx-boost), barre de
//   chargement en haut, un nouveau clic annule la page encore en route ; data-no-boost (ou
//   hx-boost="false", download, href="") : un vrai chargement ;
// - erreurs : une navigation en erreur montre la page d'erreur du serveur à la place du contenu ;
//   un fragment en erreur ou une connexion perdue : un bandeau (toast) en bas de l'écran ;
// - actions : un bouton (ou formulaire) qui envoie est occupé (aria-busy, .is-busy, désactivé)
//   jusqu'à la réponse, un second clic est ignoré ; data-no-busy pour s'en passer ;
// - rafraîchissements (hx-trigger="every …") : suspendus onglet caché, rattrapés au retour ; une
//   réponse 404/410 les arrête ;
// - vie d'une page : initPage() à chaque page (chargement, navigation, retour arrière), onSwap()
//   après chaque morceau remplacé ; minuteries d'une page : pageTimeout(), annulées en la quittant ;
// - message flash : un élément [data-flash="erreur"] retire ce paramètre de l'adresse (pas revu au
//   rechargement).

const root = document.documentElement;

// Filtre de la liste des sites, réappliqué quand les cartes se rafraîchissent. Propre à la page
// Sites : ailleurs (pas de bouton de filtre), il revient à « tous ».
let filter = "all";
function applyFilter() {
  const buttons = document.querySelectorAll("[data-filter]");
  if (!buttons.length) {
    filter = "all";
    return;
  }
  buttons.forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.filter === filter)));
  const keep = (vpn) => filter === "all" || (filter === "vpn") === vpn;
  // data-vpn vide (Trafic, Mises à jour) : un simple bloc survolé, pas filtré.
  document.querySelectorAll('table.sites tbody[data-vpn]:not([data-vpn=""])').forEach((g) => {
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

// ---- Vie d'une page ---------------------------------------------------------------------------

// Minuteries d'une page : annulées quand on la quitte par le menu (sans rechargement, elles
// survivraient et agiraient sur la page suivante).
const pageTimers = new Set();
function pageTimeout(fn, ms) {
  const id = setTimeout(() => {
    pageTimers.delete(id);
    fn();
  }, ms);
  pageTimers.add(id);
  return id;
}
function leavePage() {
  pageTimers.forEach(clearTimeout);
  pageTimers.clear();
  document.querySelectorAll("details.info[open], details.data-adder[open]").forEach((d) => (d.open = false));
}

// Rechargement demandé par le serveur (application réussie : la page repart des nouvelles valeurs,
// empreinte comprise) ; seulement si l'on est toujours sur cette page.
function armReload() {
  const r = document.querySelector("[data-reload-after]");
  if (!r || r.dataset.armed) return;
  r.dataset.armed = "1";
  pageTimeout(() => {
    if (r.isConnected) location.assign(r.dataset.reloadTo || location.href);
  }, Number(r.dataset.reloadAfter));
}

// Message flash (?erreur=…) : montré une fois ; retiré de l'adresse, il ne revient ni au
// rechargement, ni au retour arrière, ni quand un voyant relit la page.
function dropFlash() {
  const names = [...document.querySelectorAll("[data-flash]")].map((el) => el.dataset.flash || "erreur");
  if (!names.length) return;
  const u = new URL(location.href);
  let changed = false;
  for (const n of names) {
    if (u.searchParams.has(n)) {
      u.searchParams.delete(n);
      changed = true;
    }
  }
  if (changed) history.replaceState(history.state, "", u.pathname + u.search + u.hash);
}

// Après chaque morceau remplacé (et au chargement).
function onSwap() {
  labelCells();
  syncDock();
  applyFilter();
  mapInit();
  syncGrafana();
  dropFlash();
}
// À chaque nouvelle page (chargement, navigation par le menu ou un lien, retour arrière).
function initPage() {
  draftInit();
}
const isNav = (d) => !!(d && (d.boosted || d.target?.matches?.(".content")));

document.addEventListener("DOMContentLoaded", () => {
  onSwap();
  initPage();
});
document.addEventListener("htmx:afterSettle", (ev) => {
  onSwap();
  armReload(); // après un échange seulement : au chargement, la page rechargée se rechargerait sans fin
  if (isNav(ev.detail)) initPage();
});
// Le filtre et les titres de colonne dès l'échange (sans attendre la fin : pas de lignes filtrées qui
// réapparaissent un instant à chaque rafraîchissement des cartes).
document.addEventListener("htmx:afterSwap", () => {
  labelCells();
  applyFilter();
});
document.addEventListener("htmx:historyRestore", () => {
  document.querySelectorAll("[data-map][data-ready]").forEach((m) => delete m.dataset.ready);
  onSwap();
  initPage();
});

// ---- Navigation -------------------------------------------------------------------------------

// Liens du contenu : la même navigation que le menu (contenu seul, menu à jour, la plus récente
// gagne). Les formulaires classiques restent de vrais envois ; un lien href="" (recharger),
// download, ou data-no-boost reste un vrai chargement.
document.addEventListener("htmx:beforeProcessNode", (ev) => {
  const el = ev.target;
  if (!el.closest?.(".content") || el.hasAttribute("hx-boost")) return;
  if (el.tagName === "FORM") {
    el.setAttribute("hx-boost", "false");
    return;
  }
  if (el.tagName !== "A" || el.hasAttribute("hx-get") || el.hasAttribute("hx-post") || el.hasAttribute("hx-target")) return;
  const href = el.getAttribute("href");
  if (!href || href.startsWith("#") || el.hasAttribute("download") || el.hasAttribute("data-no-boost") || el.target || el.origin !== location.origin) {
    el.setAttribute("hx-boost", "false");
    return;
  }
  el.setAttribute("hx-target", ".content");
  el.setAttribute("hx-select", ".content");
  el.setAttribute("hx-select-oob", "#main-nav");
  el.setAttribute("hx-swap", "outerHTML");
  el.setAttribute("hx-sync", "closest .shell:replace");
});

// Barre de chargement : un vrai chargement (lien hors htmx), dès le clic…
document.addEventListener("click", (ev) => {
  const a = ev.target.closest?.("a[href]");
  if (!a || ev.defaultPrevented || ev.button !== 0 || ev.metaKey || ev.ctrlKey || ev.shiftKey || ev.altKey) return;
  if (a.target || a.hasAttribute("download") || a.origin !== location.origin || a.getAttribute("href").startsWith("#")) return;
  root.classList.add("nav-loading");
});
// … et une navigation htmx, le temps que le contenu arrive. Une seule à la fois : la nouvelle
// annule la précédente (sinon la plus lente, arrivée en dernier, ramenait la page abandonnée).
let navXhr = null;
document.addEventListener("htmx:beforeSend", (ev) => {
  if (!isNav(ev.detail)) return;
  if (navXhr && navXhr !== ev.detail.xhr) navXhr.abort();
  navXhr = ev.detail.xhr;
  root.classList.add("nav-loading");
});
document.addEventListener("htmx:afterRequest", (ev) => {
  if (ev.detail.xhr !== navXhr) return;
  navXhr = null;
  root.classList.remove("nav-loading");
});
// Retour arrière (page restaurée du cache du navigateur) : ni barre ni bouton restés occupés.
addEventListener("pageshow", (ev) => {
  root.classList.remove("nav-loading");
  if (ev.persisted) document.querySelectorAll("[aria-busy=true], [data-busy]").forEach(unbusy);
});

// Avant de remplacer : une navigation en erreur (4xx/5xx) montre la page d'erreur du serveur à la
// place du contenu (htmx l'ignorerait) ; quitter la page annule ses minuteries.
document.addEventListener("htmx:beforeSwap", (ev) => {
  const d = ev.detail;
  if (d.xhr.status >= 400 && d.target?.matches?.(".content") && /class="content"/.test(d.serverResponse || "")) {
    d.shouldSwap = true;
    d.isError = false;
  }
  if (d.shouldSwap && d.target?.matches?.(".content")) leavePage();
});

// Navigation par le menu : la nouvelle page part du haut. htmx amènerait sinon le contenu en haut
// de l'écran (scrollIntoViewOnBoost, coupé dans layout.html), sous la barre du haut sur téléphone.
document.addEventListener("htmx:afterSwap", (ev) => {
  if (ev.detail.boosted || ev.detail.requestConfig?.boosted) window.scrollTo(0, 0);
});

// ---- Erreurs ----------------------------------------------------------------------------------

// Bandeau en bas de l'écran (hors du contenu : il survit à la navigation). Un même message n'est
// montré qu'une fois ; sticky : jusqu'à ce qu'on le ferme (ou que la cause disparaisse).
function toast(msg, { kind = "red", key = msg, sticky = false } = {}) {
  const box = document.getElementById("toasts");
  if (!box) return null;
  let t = [...box.children].find((c) => c.dataset.key === key);
  if (!t) {
    t = document.createElement("div");
    t.className = `toast alert alert-${kind}`;
    t.setAttribute("role", kind === "red" ? "alert" : "status");
    t.dataset.key = key;
    const p = document.createElement("p");
    const close = document.createElement("button");
    close.type = "button";
    close.className = "icon-btn toast-close";
    close.setAttribute("aria-label", "Fermer");
    close.textContent = "×";
    t.append(p, close);
    box.append(t);
  }
  t.querySelector("p").textContent = msg;
  clearTimeout(t._timer);
  if (!sticky) t._timer = setTimeout(() => t.remove(), 7000);
  return t;
}
function dropToast(key) {
  document.querySelectorAll("#toasts > .toast").forEach((t) => t.dataset.key === key && t.remove());
}
document.addEventListener("click", (ev) => {
  ev.target.closest?.(".toast-close")?.closest(".toast").remove();
});

// Le texte d'une réponse en erreur : le message du serveur ([data-error], cf. layout.html), ou le
// texte brut (http.Error).
function errorText(xhr) {
  const body = xhr.responseText || "";
  if (!body.trim()) return "";
  if (!(xhr.getResponseHeader("Content-Type") || "").includes("html")) return body.trim().slice(0, 300);
  const doc = new DOMParser().parseFromString(body, "text/html");
  const el = doc.querySelector("[data-error]") || doc.querySelector(".alert") || doc.body;
  return (el?.textContent || "").replace(/\s+/g, " ").trim().slice(0, 300);
}

const isPoll = (elt) => /\bevery\b/.test(elt?.getAttribute?.("hx-trigger") || "");
// Arrête un rafraîchissement (l'élément n'existe plus côté serveur) : plus de requête toutes les 2 s.
function stopPolling(elt) {
  setTimeout(() => {
    if (!elt.isConnected) return;
    elt.setAttribute("hx-trigger", "stopped");
    htmx.process(elt);
  });
}

document.addEventListener("htmx:responseError", (ev) => {
  const d = ev.detail, st = d.xhr.status;
  if (isPoll(d.elt) && !d.requestConfig?.triggeringEvent) {
    // Un rafraîchissement en erreur passagère : le suivant réessaie, sans bandeau à chaque fois.
    if (st !== 404 && st !== 410) return;
    stopPolling(d.elt);
    toast(errorText(d.xhr) || "Cet élément n'existe plus : recharge la page.");
    return;
  }
  toast(errorText(d.xhr) || `La demande a échoué (erreur ${st}).`);
});
const netMsg = "Connexion perdue : le dashboard ne répond pas (VPN coupé ?). La page reprendra seule.";
for (const name of ["htmx:sendError", "htmx:timeout"]) {
  document.addEventListener(name, () => toast(netMsg, { key: "net", sticky: true }));
}
document.addEventListener("htmx:afterRequest", (ev) => {
  if (ev.detail.xhr?.status > 0) dropToast("net");
});
addEventListener("offline", () => toast(netMsg, { key: "net", sticky: true }));
addEventListener("online", () => dropToast("net"));

// ---- Actions : pas de double envoi ------------------------------------------------------------

// Occupé : aria-busy (lecteurs d'écran), .is-busy (style : carré qui tourne), désactivé.
function busy(el) {
  el.setAttribute("aria-busy", "true");
  el.classList.add("is-busy");
  if ("disabled" in el && !el.disabled && el.tagName !== "FORM") {
    el.disabled = true;
    el.dataset.busyDisabled = "1";
  }
}
function unbusy(el) {
  el.removeAttribute("aria-busy");
  el.classList.remove("is-busy");
  delete el.dataset.busy;
  if (el.dataset.busyDisabled) {
    el.disabled = false;
    delete el.dataset.busyDisabled;
  }
}
const busyOf = new WeakMap(); // requête → éléments rendus occupés

// Requête htmx lancée par un clic ou un envoi : le bouton (ou le bouton d'envoi du formulaire), et
// le formulaire, occupés jusqu'à la réponse. Une requête lancée par une saisie (aperçu) : rien.
document.addEventListener("htmx:beforeRequest", (ev) => {
  const d = ev.detail, elt = d.elt, trig = d.requestConfig?.triggeringEvent;
  // Onglet caché : un rafraîchissement attend le retour (cf. visibilitychange).
  if (document.visibilityState === "hidden" && isPoll(elt) && !trig) {
    elt.dataset.pollMissed = "1";
    ev.preventDefault();
    return;
  }
  if (d.boosted || !trig || (trig.type !== "click" && trig.type !== "submit") || elt.closest("[data-no-busy]")) return;
  const els = [];
  if (elt.tagName === "FORM") {
    elt.dataset.busy = "1";
    els.push(elt, ...(trig.submitter ? [trig.submitter] : elt.querySelectorAll("button:not([type=button]), input[type=submit]")));
  } else {
    els.push(elt);
  }
  els.forEach(busy);
  busyOf.set(d.xhr, els);
});
document.addEventListener("htmx:afterRequest", (ev) => {
  const els = busyOf.get(ev.detail.xhr);
  if (!els) return;
  // La page va être rechargée : rester occupé jusque-là.
  const xhr = ev.detail.xhr;
  if (xhr.getResponseHeader?.("HX-Refresh") === "true" || xhr.getResponseHeader?.("HX-Redirect")) return;
  els.forEach(unbusy);
});
// Un second clic, ou un second envoi, pendant que le premier attend sa réponse : ignoré (htmx
// l'aurait mis en file et envoyé ensuite : deux demandes à GitHub).
document.addEventListener("click", (ev) => {
  if (!ev.target.closest?.("[aria-busy=true]:is(button, a, input, .btn)")) return;
  ev.preventDefault();
  ev.stopImmediatePropagation();
}, true);
document.addEventListener("submit", (ev) => {
  if (!ev.target.dataset?.busy) return;
  ev.preventDefault();
  ev.stopImmediatePropagation();
}, true);
// Formulaire classique (envoi du navigateur) : occupé jusqu'à la page suivante. Les boutons sont
// désactivés juste après l'envoi (avant, celui qui envoie perdrait son name=value). Sans page
// suivante (téléchargement), ils reviennent au bout de 20 s.
document.addEventListener("submit", (ev) => {
  const f = ev.target;
  if (ev.defaultPrevented || f.target || f.closest("[data-no-busy]")) return;
  f.dataset.busy = "1";
  const sub = ev.submitter;
  if (sub) {
    sub.setAttribute("aria-busy", "true");
    sub.classList.add("is-busy");
  }
  setTimeout(() => f.querySelectorAll("button:not([type=button]), input[type=submit]").forEach(busy));
  setTimeout(() => {
    if (!f.isConnected) return;
    delete f.dataset.busy;
    f.querySelectorAll("[aria-busy=true]").forEach(unbusy);
  }, 20000);
});

// ---- Rafraîchissements ------------------------------------------------------------------------

// Retour sur l'onglet : les rafraîchissements suspendus partent tout de suite (même cible, mêmes
// paramètres que d'habitude).
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState !== "visible") return;
  document.querySelectorAll("[data-poll-missed]").forEach((elt) => {
    delete elt.dataset.pollMissed;
    const url = elt.getAttribute("hx-get");
    if (url && elt.isConnected) htmx.ajax("GET", url, { source: elt }).catch(() => {});
  });
});

// Voyant d'une demande : sur une page de liste, chaque changement d'état relit le contenu (les
// tableaux montrent alors le commit, puis ce que think applique), sans recharger la page.
document.addEventListener("htmx:beforeSwap", (ev) => {
  const old = ev.detail.target;
  if (!old.classList?.contains("track") || !("reload" in old.dataset)) return;
  const state = (ev.detail.serverResponse.match(/data-state="([a-z]+)"/) || [])[1];
  if (!state || state === old.dataset.state) return;
  pageTimeout(() => htmx.ajax("GET", location.pathname + location.search, { target: ".content", select: ".content", swap: "outerHTML" }).catch(() => {}), 50);
});

// ---- Composants -------------------------------------------------------------------------------

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
  const btn = ev.target.closest?.(".dd-btn");
  const opt = ev.target.closest?.(".dd-list [role=option]");
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

// Bulles d'explication : une seule ouverte, fermée par un clic ailleurs.
document.addEventListener("click", (ev) => {
  document.querySelectorAll("details.info[open]").forEach((d) => {
    if (!d.contains(ev.target)) d.open = false;
  });
});

// Grafana (page Métriques) : l'iframe vit dans un calque hors du contenu, créé une fois et posé sur
// la place réservée de la page ; masqué ailleurs, il reste chargé et revient sans rechargement
// tant qu'on navigue par le menu. Masqué plus de 10 minutes, il est vidé (il se rafraîchissait
// encore chaque minute, pour rien) : le retour le recharge.
const GRAFANA_IDLE = 10 * 60 * 1000;
let grafanaIdle = 0, grafanaFollow = false;
function syncGrafana() {
  const pane = document.getElementById("grafana-pane");
  if (!pane) return;
  const slot = document.querySelector(".grafana-slot");
  // Suivre défilement et taille seulement tant que la place existe.
  if (!!slot !== grafanaFollow) {
    grafanaFollow = !!slot;
    const fn = grafanaFollow ? addEventListener : removeEventListener;
    fn("resize", syncGrafana);
    fn("scroll", syncGrafana, { passive: true });
  }
  if (!slot) {
    if (!pane.hidden || (pane.dataset.src && !grafanaIdle)) {
      pane.hidden = true;
      clearTimeout(grafanaIdle);
      grafanaIdle = setTimeout(() => {
        pane.replaceChildren();
        delete pane.dataset.src;
      }, GRAFANA_IDLE);
    }
    return;
  }
  clearTimeout(grafanaIdle);
  grafanaIdle = 0;
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

// Bouton « Copier » des blocs de commande. Sans presse-papiers (contexte non sûr, refus) : le texte
// est sélectionné, à copier à la main.
function selectText(el) {
  if (!el) return;
  const range = document.createRange();
  range.selectNodeContents(el);
  const sel = getSelection();
  sel.removeAllRanges();
  sel.addRange(range);
}
document.addEventListener("click", (ev) => {
  const btn = ev.target.closest?.("[data-copy]");
  if (!btn) return;
  const label = btn.dataset.label || btn.textContent;
  btn.dataset.label = label;
  const src = btn.previousElementSibling;
  const text = btn.dataset.copy || src?.textContent || "";
  const flash = (msg) => {
    btn.textContent = msg;
    setTimeout(() => (btn.textContent = label), 1500);
  };
  const p = navigator.clipboard?.writeText(text) ?? Promise.reject(new Error("presse-papiers absent"));
  p.then(() => flash("Copié"), () => {
    selectText(src);
    flash("Sélectionné");
  });
});

// Aperçu JSON : remplacé à chaque modification ; sa position de défilement est gardée.
let previewScroll = null;
document.addEventListener("htmx:beforeSwap", () => {
  const body = document.querySelector("#preview .code-body");
  if (body) previewScroll = { top: body.scrollTop, left: body.scrollLeft };
});
document.addEventListener("htmx:afterSettle", () => {
  const body = document.querySelector("#preview .code-body");
  if (body && previewScroll) {
    body.scrollTop = previewScroll.top;
    body.scrollLeft = previewScroll.left;
  }
});

// Brouillon de la page d'un site : gardé dans l'onglet (sessionStorage) à chaque modification, rejoué
// au rechargement si le site n'a pas changé sur main (empreinte `base`), oublié une fois appliqué.
const draftKey = () => "draft:" + location.pathname + location.search;
const draftOf = (form) => new URLSearchParams(new FormData(form)).toString();
let draftPristine = null; // la page telle que main l'a donnée
function draftStore(value) {
  try {
    if (value == null) sessionStorage.removeItem(draftKey());
    else sessionStorage.setItem(draftKey(), value);
  } catch {}
}
function draftLoad() {
  try { return sessionStorage.getItem(draftKey()); } catch { return null; }
}
function draftBar(show) {
  const bar = document.getElementById("draft-bar");
  if (bar) bar.hidden = !show;
}
function draftInit() {
  draftPristine = null;
  const form = document.getElementById("site-form");
  if (!form || location.pathname === "/sites/new" || !/^\/sites\/[^/]+$/.test(location.pathname)) return;
  // Une demande court (formulaire inerte) : le brouillon est gardé tel quel. Réussie, main change
  // et l'empreinte avec (brouillon oublié au rechargement) ; échouée, il revient avec sa barre.
  if (form.hasAttribute("inert")) return;
  draftPristine = draftOf(form);
  const saved = draftLoad();
  if (!saved || saved === draftPristine) return;
  if (new URLSearchParams(saved).get("base") !== form.elements.base?.value) return draftStore(null);
  fetch(form.dataset.formUrl, { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded", "HX-Request": "true" }, body: saved })
    .then((r) => (r.ok ? r.text() : Promise.reject(r.status)))
    .then((html) => {
      if (!form.isConnected) return;
      htmx.swap("#editor-body", html, { swapStyle: "outerHTML" });
      draftBar(true);
    })
    .catch(() => draftStore(null));
}
document.addEventListener("htmx:afterSettle", (ev) => {
  const form = document.getElementById("site-form");
  // Page qui vient d'arriver : rien de modifié (draftInit vient de la lire, et la rejoue peut-être).
  if (!form || draftPristine === null || form.hasAttribute("inert") || isNav(ev.detail)) return;
  const now = draftOf(form);
  draftStore(now === draftPristine ? null : now);
  draftBar(now !== draftPristine);
});
document.addEventListener("click", (ev) => {
  if (!ev.target.closest?.("[data-draft-drop]")) return;
  ev.preventDefault();
  draftStore(null);
  location.reload();
});

// Carte du Trafic (Mercator, à ses proportions) : zoom à la molette, au pincement (pavé tactile : molette + Ctrl ; écran :
// deux doigts), aux boutons ou au double clic ; déplacement en glissant ou à deux doigts sur le pavé.
// Le zoom glisse vers sa cible (animation) ; la carte tourne sans fin de gauche à droite (trois
// copies, la vue ramenée sur celle du milieu), reste bornée en haut et en bas ; les points gardent à
// peu près leur taille à l'écran, et leur survol montre les sites visités depuis là.
// Au départ : le monde entier. Dézoomée au maximum, un doigt fait défiler la page (comme la
// molette) : on zoome alors en pinçant, au double appui ou au bouton +.
const MAP_W = 360, MAP_MAX = 150;
function mapInit() {
  document.querySelectorAll("[data-map]:not([data-ready])").forEach((frame) => {
    frame.dataset.ready = "1";
    const svg = frame.querySelector("svg");
    const MAP_H = +svg.dataset.h, MAP_RATIO = MAP_H / MAP_W;
    const world = () => ({ x: 0, y: 0, w: MAP_W });
    const clamp = (v) => {
      const w = Math.min(MAP_W, Math.max(MAP_W / MAP_MAX, v.w)), h = w * MAP_RATIO;
      const y = h >= MAP_H ? (MAP_H - h) / 2 : Math.min(MAP_H - h, Math.max(0, v.y));
      return { x: v.x, y, w };
    };
    const zoomedOut = () => target.w >= MAP_W - 1e-6;
    // Les bulles, lues une fois ; leur rayon n'est réécrit que si l'échelle a bougé de plus de 1 %.
    const bubbles = [...svg.querySelectorAll("circle[data-r]")].map((c) => [c, +c.dataset.r]);
    let view = world(), target = view, frameReq = 0, lastK = 0;
    const draw = () => {
      svg.setAttribute("viewBox", `${view.x} ${view.y} ${view.w} ${view.w * MAP_RATIO}`);
      const k = (view.w / MAP_W) ** 0.85;
      if (Math.abs(k - lastK) > lastK * 0.01) {
        lastK = k;
        for (const [c, r] of bubbles) c.setAttribute("r", r * k);
      }
      frame.classList.toggle("zoomed-out", zoomedOut());
    };
    // Vers la cible, à chaque image (zoom en douceur) ; `now` : sans animation (glisser, pincer).
    const go = (v, now) => {
      target = clamp(v);
      // Sortie de la copie du milieu : la vue (et l'animation en cours) recule ou avance d'un tour.
      const turn = Math.floor(target.x / MAP_W) * MAP_W;
      if (turn) {
        target = { ...target, x: target.x - turn };
        view = { ...view, x: view.x - turn };
      }
      if (now) {
        view = target;
        draw();
        return;
      }
      if (frameReq) return;
      const step = () => {
        const d = (a, b) => a + (b - a) * 0.3;
        view = { x: d(view.x, target.x), y: d(view.y, target.y), w: d(view.w, target.w) };
        if (Math.abs(view.w - target.w) < target.w * 0.002 && Math.abs(view.x - target.x) < target.w * 0.002) view = target;
        draw();
        frameReq = view === target ? 0 : requestAnimationFrame(step);
      };
      frameReq = requestAnimationFrame(step);
    };
    // Rapproche de `f` (> 1) autour du point (cx, cy) de la carte, à partir de la cible en cours.
    const zoom = (f, cx, cy, now) => {
      const t = target, w = Math.min(MAP_W, Math.max(MAP_W / MAP_MAX, t.w / f)), r = w / t.w;
      go({ x: cx - (cx - t.x) * r, y: cy - (cy - t.y) * r, w }, now);
    };
    const toMap = (clientX, clientY, v = view) => {
      const b = svg.getBoundingClientRect();
      return [v.x + ((clientX - b.left) / b.width) * v.w, v.y + ((clientY - b.top) / b.height) * v.w * MAP_RATIO];
    };
    const perPixel = () => view.w / svg.getBoundingClientRect().width;
    frame.addEventListener("wheel", (ev) => {
      // Dézoomée au maximum, la carte laisse défiler la page ; on zoome alors avec Ctrl + molette,
      // le pincement, le double-clic ou le bouton +.
      if (!ev.ctrlKey && zoomedOut()) return;
      ev.preventDefault();
      const px = ev.deltaMode === 1 ? 33 : ev.deltaMode === 2 ? 400 : 1;
      const dy = ev.deltaY * px, dx = ev.deltaX * px;
      // Molette de souris : par crans (lignes, ou pixels ronds sans mouvement de côté).
      const mouse = ev.deltaMode !== 0 || (dx === 0 && Math.abs(dy) >= 50 && Number.isInteger(dy));
      if (ev.ctrlKey || mouse) {
        zoom(Math.exp(-dy * (ev.ctrlKey ? 0.012 : 0.0022)), ...toMap(ev.clientX, ev.clientY, target), ev.ctrlKey);
      } else {
        const s = perPixel();
        go({ x: target.x + dx * s, y: target.y + dy * s, w: target.w }, true);
      }
    }, { passive: false });
    frame.addEventListener("dblclick", (ev) => zoom(2.5, ...toMap(ev.clientX, ev.clientY, target)));
    frame.querySelectorAll("[data-zoom]").forEach((b) => b.addEventListener("click", () => {
      if (b.dataset.zoom === "reset") go(world());
      else zoom(b.dataset.zoom === "in" ? 2 : 0.5, target.x + target.w / 2, target.y + (target.w * MAP_RATIO) / 2);
    }));
    // Glisser (un doigt, la souris) et pincer (deux doigts : zoom et déplacement ensemble).
    const pointers = new Map();
    let pinch = null;
    let tap = null; // l'appui d'un doigt, tant qu'il n'a pas glissé
    let loose = false; // un doigt sur la carte dézoomée : la page défile, la carte ne bouge pas

    const pair = () => {
      const [a, b] = [...pointers.values()];
      return { cx: (a[0] + b[0]) / 2, cy: (a[1] + b[1]) / 2, d: Math.hypot(a[0] - b[0], a[1] - b[1]) };
    };
    frame.addEventListener("pointerdown", (ev) => {
      if (ev.target.closest("button")) return;
      if (!pointers.size) loose = ev.pointerType === "touch" && zoomedOut();
      pointers.set(ev.pointerId, [ev.clientX, ev.clientY]);
      // Deux doigts : la carte prend la main (pincement), même dézoomée.
      if (pointers.size === 2) {
        loose = false;
        for (const id of pointers.keys()) {
          try { frame.setPointerCapture(id); } catch {}
        }
      } else if (!loose) {
        frame.setPointerCapture(ev.pointerId);
      }
      pinch = pointers.size === 2 ? pair() : null;
      tap = pointers.size === 1 ? [ev.clientX, ev.clientY] : null;
      if (!loose) frame.classList.add("dragging");
      frame.querySelector(".map-tip").hidden = true;
    });
    frame.addEventListener("pointermove", (ev) => {
      const prev = pointers.get(ev.pointerId);
      if (!prev) return;
      pointers.set(ev.pointerId, [ev.clientX, ev.clientY]);
      if (tap && Math.hypot(ev.clientX - tap[0], ev.clientY - tap[1]) > 6) tap = null;
      if (pointers.size === 1) {
        if (loose) return;
        const s = perPixel();
        go({ x: view.x - (ev.clientX - prev[0]) * s, y: view.y - (ev.clientY - prev[1]) * s, w: view.w }, true);
      } else if (pointers.size === 2 && pinch) {
        const now = pair();
        // Le point de la carte sous l'ancien centre des doigts passe sous le nouveau.
        const [mx, my] = toMap(pinch.cx, pinch.cy);
        const w = Math.min(MAP_W, Math.max(MAP_W / MAP_MAX, view.w * (pinch.d / Math.max(now.d, 1))));
        const b = svg.getBoundingClientRect();
        const fx = (now.cx - b.left) / b.width, fy = (now.cy - b.top) / b.height;
        go({ x: mx - fx * w, y: my - fy * w * MAP_RATIO, w }, true);
        pinch = now;
      }
    });
    const release = (ev) => {
      // Un appui sans glisser (au doigt, pas de survol) : l'info-bulle du point le plus proche.
      if (ev.type === "pointerup" && tap && pointers.size === 1) {
        const spot = nearestSpot(ev.clientX, ev.clientY);
        if (spot) show(spot, ev);
      }
      tap = null;
      pointers.delete(ev.pointerId);
      pinch = pointers.size === 2 ? pair() : null;
      if (!pointers.size) {
        frame.classList.remove("dragging");
        loose = false;
      }
    };
    frame.addEventListener("pointerup", release);
    frame.addEventListener("pointercancel", release);
    // Info-bulle d'un point : le lieu, le nombre, et les sites visités depuis là (texte seul).
    const tip = frame.querySelector(".map-tip");
    const place = (ev) => {
      const b = frame.getBoundingClientRect();
      const x = ev.clientX - b.left, y = ev.clientY - b.top;
      tip.style.left = `${Math.min(x + 14, b.width - tip.offsetWidth - 8)}px`;
      tip.style.top = `${y + tip.offsetHeight + 24 > b.height ? y - tip.offsetHeight - 12 : y + 14}px`;
    };
    // Le point à moins de 24 px du doigt (les petits points sont durs à viser).
    const nearestSpot = (cx, cy) => {
      let best = null, dist = 24;
      for (const spot of svg.querySelectorAll(".spot")) {
        const r = spot.getBoundingClientRect();
        const d = Math.max(0, Math.hypot(r.left + r.width / 2 - cx, r.top + r.height / 2 - cy) - r.width / 2);
        if (d <= dist) [best, dist] = [spot, d];
      }
      return best;
    };
    const show = (spot, ev) => {
      const head = document.createElement("strong");
      head.textContent = spot.dataset.label;
      const count = document.createElement("small");
      count.textContent = spot.dataset.count;
      const list = document.createElement("ul");
      // Par site : son nombre, puis ses chemins les plus vus (« domaine, n, plus, chemin, n, … »).
      const row = (cls, a, b) => {
        const li = document.createElement("li");
        li.className = cls;
        const x = document.createElement("span");
        x.textContent = a;
        const y = document.createElement("span");
        y.textContent = b;
        li.append(x, y);
        return li;
      };
      for (const line of (spot.dataset.sites || "").split("\n").filter(Boolean)) {
        const [domain, n, more, ...paths] = line.split("\t");
        list.append(row("tip-site", domain, n));
        for (let i = 0; i + 1 < paths.length; i += 2) list.append(row("tip-path", paths[i], paths[i + 1]));
        if (+more > 0) list.append(row("tip-path tip-more", `et ${more} autre${+more > 1 ? "s" : ""}`, ""));
      }
      tip.replaceChildren(head, count, ...(list.children.length ? [list] : []));
      tip.className = `map-tip tip-${spot.classList.contains("spot-vpn") ? "vpn" : "internet"}`;
      tip.hidden = false;
      place(ev);
    };
    svg.addEventListener("pointerover", (ev) => {
      const spot = ev.target.closest(".spot");
      if (spot && ev.pointerType === "mouse" && pointers.size === 0) show(spot, ev);
    });
    svg.addEventListener("pointermove", (ev) => { if (!tip.hidden && ev.pointerType === "mouse") place(ev); });
    svg.addEventListener("pointerout", (ev) => {
      if (ev.pointerType === "mouse" && ev.target.closest(".spot") && !ev.relatedTarget?.closest?.(".spot")) tip.hidden = true;
    });
    draw();
  });
}

// Un bouton qui déplie la ligne suivante d'un tableau (analyse d'une mise à jour).
document.addEventListener("click", (ev) => {
  const b = ev.target.closest?.("[data-toggle-next]");
  if (!b) return;
  const row = b.closest("tr")?.nextElementSibling;
  if (!row) return;
  row.hidden = !row.hidden;
  b.setAttribute("aria-expanded", String(!row.hidden));
});

// Sur téléphone, les tableaux deviennent des cartes sans en-tête : chaque cellule reçoit le titre de
// sa colonne (data-label), affiché à côté de sa valeur (style.css). Un tableau sans en-tête (les
// lignes repliées des Mises à jour) prend celui du premier tableau de sa carte. Les cellules
// fusionnées sur plusieurs lignes (rowspan) sont comptées : les lignes suivantes commencent plus
// loin. Un data-label écrit par le template est gardé tel quel.
function labelCells() {
  document.querySelectorAll("table").forEach((t) => {
    const head = t.tHead || t.closest(".table-card")?.querySelector("thead");
    if (!head) return;
    const labels = [];
    head.querySelectorAll("th").forEach((th) => {
      const text = th.querySelector(".sr-only") ? "" : th.textContent.trim();
      for (let i = 0; i < th.colSpan; i++) labels.push(text);
    });
    for (const tbody of t.tBodies) {
      let carry = []; // colonne → lignes encore couvertes par une cellule du dessus
      for (const tr of tbody.rows) {
        const next = [];
        let col = 0;
        for (const td of tr.cells) {
          while (carry[col] > 0) col++;
          if (td.colSpan === 1 && labels[col] && !td.dataset.label) td.dataset.label = labels[col];
          if (td.rowSpan > 1) for (let i = 0; i < td.colSpan; i++) next[col + i] = td.rowSpan - 1;
          col += td.colSpan;
        }
        carry.forEach((n, c) => {
          if (n > 1) next[c] = Math.max(next[c] || 0, n - 1);
        });
        carry = next;
      }
    }
  });
}

// ---- Barre de l'éditeur sur téléphone ---------------------------------------------------------

// #edit-dock recopie l'état de l'aperçu (#preview : data-dirty, data-adds, data-dels, data-errors) :
// visible seulement s'il y a des changements ; « Voir » mène à l'aperçu, « Appliquer » clique le
// vrai bouton (mêmes garde-fous : occupé, pas de double envoi). Pas de requête en plus.
function syncDock() {
  const dock = document.getElementById("edit-dock");
  if (!dock) return;
  const pv = document.getElementById("preview");
  const apply = pv?.querySelector(".code-foot .btn-primary[hx-post]");
  if (!pv || pv.dataset.dirty !== "1" || !apply) {
    dock.hidden = true;
    return;
  }
  const errs = Number(pv.dataset.errors || 0);
  dock.querySelector("[data-dock-sum]").textContent =
    `+${pv.dataset.adds} −${pv.dataset.dels}` + (errs ? ` · ${errs} erreur${errs > 1 ? "s" : ""}` : "");
  const btn = dock.querySelector("[data-dock-apply]");
  btn.textContent = apply.textContent;
  btn.disabled = apply.disabled;
  dock.hidden = false;
}
document.addEventListener("click", (ev) => {
  const show = ev.target.closest?.("#edit-dock [data-dock-show]");
  const go = ev.target.closest?.("#edit-dock [data-dock-apply]");
  if (!show && !go) return;
  const pv = document.getElementById("preview");
  if (!pv) return;
  if (show) {
    pv.scrollIntoView({ behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth", block: "start" });
    return;
  }
  pv.querySelector(".code-foot .btn-primary[hx-post]")?.click();
});

// ---- Page à ne pas quitter par mégarde ---------------------------------------------------------

// [data-leave-warn] (ex. un appareil VPN ajouté : ses clés ne se remontrent pas) : quitter la page,
// par le navigateur ou par un lien du dashboard, demande confirmation.
addEventListener("beforeunload", (ev) => {
  if (!document.querySelector("[data-leave-warn]")) return;
  ev.preventDefault();
  ev.returnValue = "";
});
document.addEventListener("htmx:beforeRequest", (ev) => {
  if (!isNav(ev.detail)) return;
  const warn = document.querySelector("[data-leave-warn]");
  if (warn && !confirm(warn.dataset.leaveWarn)) {
    ev.preventDefault();
    root.classList.remove("nav-loading");
  }
}, true);
