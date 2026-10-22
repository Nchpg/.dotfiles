// Comportements purement visuels ; tout ce qui compte (JSON, validation, diff) se fait côté serveur.

// Favicon absente : on garde l'initiale.
document.addEventListener("error", (ev) => {
  if (ev.target.matches && ev.target.matches("img[data-fallback]")) ev.target.remove();
}, true);

// Filtre de la liste des sites, réappliqué quand les cartes se rafraîchissent.
let filter = "all";
function applyFilter() {
  document.querySelectorAll(".segmented [data-filter]").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.filter === filter)));
  document.querySelectorAll(".card.site").forEach((c) => {
    const vpn = c.dataset.vpn === "true";
    c.hidden = filter === "vpn" ? !vpn : filter === "public" ? vpn : false;
  });
}
document.addEventListener("click", (ev) => {
  const btn = ev.target.closest && ev.target.closest(".segmented [data-filter]");
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
