// Reste au placeholder en file:// : boutons « appliquer » masqués via .static.
const TOKEN = '__THEME_TOKEN__';
if (TOKEN.startsWith('__')) document.body.classList.add('static');

let CURRENT = {};
try { CURRENT = JSON.parse('__THEME_CURRENT__'); } catch (err) { CURRENT = {}; }

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
    // Clipboard API refusée (file://, permission) : repli par sélection.
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
    FAVORITES = new Set(data.favorites);
    markFavorites();
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
    // Le serveur coupe la connexion en répondant : erreur attendue.
  }
  doneBtn.textContent = 'terminé';
  showToast('Session terminée — la suite se passe dans le terminal. Tu peux fermer cet onglet.', 'ok');
  for (const b of document.querySelectorAll('button.apply')) b.disabled = true;
});

refilter();
// preventScroll : l'en-tête sticky fait sur-corriger le navigateur.
search.focus({ preventScroll: true });
