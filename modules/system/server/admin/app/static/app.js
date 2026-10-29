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
  const form = document.getElementById("site-form");
  if (!form || location.pathname === "/sites/new" || !/^\/sites\/[^/]+$/.test(location.pathname)) return;
  // Une demande court (formulaire inerte) : ce qui était en brouillon vient d'être appliqué.
  if (form.hasAttribute("inert")) return draftStore(null);
  draftPristine = draftOf(form);
  const saved = draftLoad();
  if (!saved || saved === draftPristine) return;
  if (new URLSearchParams(saved).get("base") !== form.elements.base.value) return draftStore(null);
  fetch(form.dataset.formUrl, { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded", "HX-Request": "true" }, body: saved })
    .then((r) => (r.ok ? r.text() : Promise.reject(r.status)))
    .then((html) => {
      htmx.swap("#editor-body", html, { swapStyle: "outerHTML" });
      draftBar(true);
    })
    .catch(() => draftStore(null));
}
document.addEventListener("DOMContentLoaded", draftInit);
document.addEventListener("htmx:afterSettle", () => {
  const form = document.getElementById("site-form");
  if (!form || draftPristine === null || form.hasAttribute("inert")) return;
  const now = draftOf(form);
  draftStore(now === draftPristine ? null : now);
  draftBar(now !== draftPristine);
});
document.addEventListener("click", (ev) => {
  if (!ev.target.closest?.("[data-draft-drop]")) return;
  draftStore(null);
  location.reload();
});

// Carte du Trafic (Mercator, à ses proportions) : zoom à la molette, au pincement (pavé tactile : molette + Ctrl ; écran :
// deux doigts), aux boutons ou au double clic ; déplacement en glissant ou à deux doigts sur le pavé.
// Le zoom glisse vers sa cible (animation) ; la carte tourne sans fin de gauche à droite (trois
// copies, la vue ramenée sur celle du milieu), reste bornée en haut et en bas ; les points gardent à
// peu près leur taille à l'écran, et leur survol montre les sites visités depuis là.
// Au départ : le monde entier.
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
    let view = world(), target = view, frameReq = 0;
    const draw = () => {
      svg.setAttribute("viewBox", `${view.x} ${view.y} ${view.w} ${view.w * MAP_RATIO}`);
      const k = (view.w / MAP_W) ** 0.85;
      svg.querySelectorAll("circle[data-r]").forEach((c) => c.setAttribute("r", c.dataset.r * k));
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

    const pair = () => {
      const [a, b] = [...pointers.values()];
      return { cx: (a[0] + b[0]) / 2, cy: (a[1] + b[1]) / 2, d: Math.hypot(a[0] - b[0], a[1] - b[1]) };
    };
    frame.addEventListener("pointerdown", (ev) => {
      if (ev.target.closest("button")) return;
      frame.setPointerCapture(ev.pointerId);
      pointers.set(ev.pointerId, [ev.clientX, ev.clientY]);
      pinch = pointers.size === 2 ? pair() : null;
      tap = pointers.size === 1 ? [ev.clientX, ev.clientY] : null;
      frame.classList.add("dragging");
      frame.querySelector(".map-tip").hidden = true;
    });
    frame.addEventListener("pointermove", (ev) => {
      const prev = pointers.get(ev.pointerId);
      if (!prev) return;
      pointers.set(ev.pointerId, [ev.clientX, ev.clientY]);
      if (tap && Math.hypot(ev.clientX - tap[0], ev.clientY - tap[1]) > 6) tap = null;
      if (pointers.size === 1) {
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
      if (!pointers.size) frame.classList.remove("dragging");
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
      for (const line of (spot.dataset.sites || "").split("\n").filter(Boolean)) {
        const [domain, n] = line.split("\t");
        const li = document.createElement("li");
        const d = document.createElement("span");
        d.textContent = domain;
        const c = document.createElement("span");
        c.textContent = n;
        li.append(d, c);
        list.append(li);
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
document.addEventListener("DOMContentLoaded", mapInit);
document.addEventListener("htmx:afterSettle", mapInit);

// Un bouton qui déplie la ligne suivante d'un tableau (analyse d'une mise à jour).
document.addEventListener("click", (ev) => {
  const b = ev.target.closest("[data-toggle-next]");
  if (!b) return;
  const row = b.closest("tr")?.nextElementSibling;
  if (!row) return;
  row.hidden = !row.hidden;
  b.setAttribute("aria-expanded", String(!row.hidden));
});

// Sur téléphone, les tableaux deviennent des cartes sans en-tête : chaque cellule reçoit le titre de
// sa colonne (data-label), affiché à côté de sa valeur (style.css). Un tableau sans en-tête (les
// lignes repliées des Mises à jour) prend celui du premier tableau de sa carte.
function labelCells() {
  document.querySelectorAll("table").forEach((t) => {
    const head = t.tHead || t.closest(".table-card")?.querySelector("thead");
    if (!head) return;
    const labels = [];
    head.querySelectorAll("th").forEach((th) => {
      const text = th.querySelector(".sr-only") ? "" : th.textContent.trim();
      for (let i = 0; i < th.colSpan; i++) labels.push(text);
    });
    t.querySelectorAll("tbody tr").forEach((tr) => {
      let col = 0;
      for (const td of tr.cells) {
        if (td.colSpan === 1 && labels[col] && !td.dataset.label) td.dataset.label = labels[col];
        col += td.colSpan;
      }
    });
  });
}
document.addEventListener("DOMContentLoaded", labelCells);
document.addEventListener("htmx:afterSettle", labelCells);
