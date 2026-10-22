// Comportements purement visuels ; tout ce qui compte (JSON, validation, diff) se fait côté serveur.

// Favicon absente : on garde l'initiale.
document.addEventListener("error", (ev) => {
  if (ev.target.matches && ev.target.matches("img[data-fallback]")) ev.target.remove();
}, true);

function refresh(root) {
  // Filtre de la liste des sites.
  root.querySelectorAll(".segmented [data-filter]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const f = btn.dataset.filter;
      btn.parentElement.querySelectorAll("button").forEach((b) => b.setAttribute("aria-pressed", String(b === btn)));
      document.querySelectorAll(".card.site").forEach((c) => {
        const vpn = c.dataset.vpn === "true";
        c.hidden = f === "vpn" ? !vpn : f === "public" ? vpn : false;
      });
    });
  });
}

// Exposition : appareils et suffixe d'adresse suivent le choix public / VPN.
document.addEventListener("change", (ev) => {
  const form = ev.target.closest && ev.target.closest("#site-form");
  if (!form || ev.target.name !== "expose") return;
  const vpn = ev.target.value === "vpn";
  form.querySelectorAll("[data-vpn-only]").forEach((el) => (el.hidden = !vpn));
  form.querySelectorAll("[data-suffix]").forEach((el) => (el.textContent = vpn ? el.dataset.vpn : el.dataset.public));
});

document.addEventListener("DOMContentLoaded", () => refresh(document));

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
