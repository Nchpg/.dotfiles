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

function refilter() {
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

search.addEventListener('input', refilter);
for (const btn of filterButtons) {
  btn.addEventListener('click', () => {
    activeFilter = btn.dataset.filter;
    for (const b of filterButtons) b.setAttribute('aria-pressed', String(b === btn));
    refilter();
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

// POST JSON authentifié (jeton ajouté ici) ; rend la réponse décodée, ou lève
// avec le message d'erreur du serveur.
async function postJson(path, body) {
  const res = await fetch(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ token: TOKEN, ...body }),
  });
  const data = await res.json();
  if (!res.ok) throw new Error(data.error || ('HTTP ' + res.status));
  return data;
}

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
    const data = await postJson('/apply', { name, slot });
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
    const data = await postJson('/favorite', { name, on });
    // On repart de la liste renvoyée par le serveur, pas d'un état deviné
    // côté client : le fichier reste la source de vérité.
    FAVORITES = new Set(data.favorites);
    markFavorites();
    // Le filtre « favoris » doit refléter le retrait immédiatement.
    if (activeFilter === 'favorite') refilter();
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

refilter();
// preventScroll : sans ça, focus() fait défiler la page pour « amener le
// champ dans la vue » — et comme l'en-tête est en position:sticky, le
// navigateur sur-corrige et on arrive sous le titre au lieu du haut de page.
search.focus({ preventScroll: true });
