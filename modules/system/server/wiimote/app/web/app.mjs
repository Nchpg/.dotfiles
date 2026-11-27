import { G, gyroPointer, screenFrom, turnTo, dpadDirection, holdAngle, oneEuro, stickDirections, tiltGain, toLocal, wheelItem, wheelMotion, toDSU, upFromOrientation } from './motion.mjs';

// Bit de chaque bouton dans le message : même ordre que `buttons` dans dsu.go, puis Secouer (`shakeBit`), dont
// le serveur joue lui-même la secousse vers Dolphin.
const BIT = { A: 0, B: 1, 1: 2, 2: 3, '-': 4, '+': 5, Home: 6, Up: 7, Down: 8, Left: 9, Right: 10, Shake: 11 };

// Flèche vue à l'écran → bouton de la Wiimote. De côté, son haut (côté capteur) est à gauche.
const DPAD = {
  vertical: { up: 'Up', down: 'Down', left: 'Left', right: 'Right' },
  sideways: { left: 'Up', right: 'Down', up: 'Right', down: 'Left' },
};

const stage = document.getElementById('stage');
const overlay = document.getElementById('overlay');
const status = document.getElementById('status');
const startButton = document.getElementById('start');
const modeButton = document.getElementById('mode');
const joystick = document.getElementById('joystick');
const knob = joystick.querySelector('i');
const aimButton = document.getElementById('aim');
const nameInput = document.getElementById('name');
const leds = [...document.querySelectorAll('.leds i')];

const pointers = new Map();
// Boutons, mouvement, pointeur (30 octets), puis le nombre d'appuis de chaque bouton (un octet par bit, modulo 256) :
// le serveur rejoue ainsi un appui même si le réseau a perdu ou groupé les messages où il était enfoncé (buttons.go).
const packet = new DataView(new ArrayBuffer(30 + 16));
const presses = new Uint8Array(packet.buffer, 30);
let buttons = 0;
let motion = [0, -1, 0, 0, 0, 0];
// Pointeur envoyé sur 16 bits (32768 : centre), calé par le calibrage du bouton ⌖.
const AIM_CENTER = 1 << 15;
let aim = [AIM_CENTER, AIM_CENTER];
// Lissage du pointeur (réglage ⚙), du plus léger au plus fort : moins de tremblement, plus de retard. Aucun par
// défaut. null : à recréer (au calibrage, au changement de réglage).
const SMOOTHING = [
  null,
  { minCutoff: 5, beta: 20, dCutoff: 5 },
  { minCutoff: 3, beta: 15, dCutoff: 3 },
  { minCutoff: 1, beta: 7, dCutoff: 1 },
];
const SMOOTHING_LABELS = ['aucun', 'léger', 'moyen', 'fort'];
let aimFilters = null;
// Visée au gyroscope (gyroPointer).
const pointer = gyroPointer();
// Écran de la télé calibré (screenFrom) ; pendant le calibrage, les directions visées à ses coins ; recentrage
// (turnTo) contre la lente dérive du gyroscope.
let tv;
let aimed = null;
let recentre = (v) => v;
let ws;
let lastError = '';
// Liaison directe (WebTransport, UDP) que donne le serveur : les états y partent en datagrammes numérotés, sans
// Cloudflare ni TCP, qui retient tout derrière un paquet perdu. Le WebSocket reste en repli.
let direct = null;
const datagram = new DataView(new ArrayBuffer(8 + packet.byteLength));
let wakeLock;

// Selon le navigateur, accelerationIncludingGravity n'a pas toujours le signe de la spec : on le recoupe
// avec la verticale que donne deviceorientation, sur les premiers échantillons au repos.
let accelSign = 1;
let orientation;
let agreement = 0;
let samples = 0;

function store(key, value) {
  try {
    if (value === undefined) return localStorage.getItem(key);
    localStorage.setItem(key, value);
  } catch {
    return null;
  }
}

// Tenue choisie au bouton, jamais déduite de la rotation de l'écran.
let mode = store('mode') === 'vertical' ? 'vertical' : 'sideways';
// Angle d'écran pour lequel l'interface est droite (horizontale : haut du téléphone à gauche par défaut).
let hold = mode === 'sideways' ? 90 : 0;

const liveAngle = () => (((screen.orientation?.angle ?? window.orientation ?? 0) % 360) + 360) % 360;

// Tourne la scène de l'écart entre la tenue et l'écran : l'interface reste fixe dans la main.
function layout() {
  const live = liveAngle();
  hold = holdAngle(hold, live, mode === 'sideways');
  const turned = (hold - live) % 180 !== 0;
  // Taille de la page, pas de la zone visible : zoomée (iOS), innerWidth rétrécit, et la scène avec.
  const { clientWidth: width, clientHeight: height } = document.documentElement;
  stage.style.width = `${turned ? height : width}px`;
  stage.style.height = `${turned ? width : height}px`;
  stage.style.transform = `translate(-50%, -50%) rotate(${hold - live}deg)`;
  document.body.classList.toggle('sideways', mode === 'sideways');
}
addEventListener('resize', layout);
screen.orientation?.addEventListener('change', layout);
layout();

// iOS ignore user-scalable=no : un pincement à deux pouces zoomait la page, et touch-action empêchait ensuite de
// dézoomer. Les gestes de Safari sont bloqués ; un zoom qui passerait quand même est annulé en remettant la borne
// d'échelle du viewport.
for (const type of ['gesturestart', 'gesturechange']) document.addEventListener(type, (e) => e.preventDefault());
document.addEventListener('touchmove', (e) => e.touches.length > 1 && e.preventDefault(), { passive: false });
const viewport = document.querySelector('meta[name="viewport"]');
const viewportContent = viewport.content;
window.visualViewport?.addEventListener('resize', () => {
  if (visualViewport.scale < 1.01) return;
  viewport.content = viewportContent.replace(', maximum-scale=1', '');
  requestAnimationFrame(() => {
    viewport.content = viewportContent;
  });
});

// Android, en plein écran ou installée : l'écran ne bascule même plus. Ailleurs, `layout` compense.
function lockOrientation() {
  screen.orientation?.lock?.(mode === 'sideways' ? 'landscape' : 'portrait')?.catch(() => {});
}

// Thème : celui du système au départ, puis celui choisi au bouton, mémorisé.
let theme = store('theme') ?? (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
document.documentElement.dataset.theme = theme;
document.getElementById('theme').addEventListener('click', () => {
  theme = theme === 'dark' ? 'light' : 'dark';
  document.documentElement.dataset.theme = theme;
  store('theme', theme);
});

// Croix ou joystick, au choix, mémorisé.
// Croix, joystick ou volant (joystick qui remplace l'inclinaison, pour Mario Kart), au choix, mémorisé.
const CONTROLS = ['dpad', 'stick', 'wheel'];
let control = CONTROLS.includes(store('control')) ? store('control') : 'dpad';
function showControl() {
  document.body.classList.toggle('stick', control !== 'dpad');
  document.body.classList.toggle('wheel', control === 'wheel');
}
showControl();
document.getElementById('pad').addEventListener('click', () => {
  control = CONTROLS[(CONTROLS.indexOf(control) + 1) % CONTROLS.length];
  store('control', control);
  showControl();
});
// Volant tenu : position du joystick (−1 à 1), qui remplace l'inclinaison ; null : l'inclinaison reprend.
let steer = null;
// Coup de pouce du joystick volant en cours (cf. `wheelItem`).
let flick = { calm: 0, item: null };

// Réglages du panneau ⚙, mémorisés : B à côté de A, sensibilités de l'inclinaison et du joystick volant.
const panel = document.getElementById('panel');
const gain = (key) => Math.min(2, Math.max(0.5, Number(store(key)) || 1));
const settings = {
  bByA: store('bByA') === '1',
  tilt: gain('tilt'),
  stick: gain('stick'),
  smooth: Math.min(3, Math.max(0, Math.round(Number(store('smooth')) || 0))),
};
const times = (k) => `×${k.toFixed(1).replace('.', ',')}`;
function showSettings() {
  document.getElementById('bByA').checked = settings.bByA;
  document.body.classList.toggle('b-by-a', settings.bByA);
  for (const key of ['tilt', 'stick']) {
    document.getElementById(key).value = settings[key];
    document.getElementById(`${key}Out`).textContent = times(settings[key]);
  }
  document.getElementById('smooth').value = settings.smooth;
  document.getElementById('smoothOut').textContent = SMOOTHING_LABELS[settings.smooth];
}
showSettings();
document.getElementById('settingsForm').addEventListener('input', (e) => {
  if (e.target.type === 'checkbox') {
    settings[e.target.id] = e.target.checked;
    store(e.target.id, e.target.checked ? '1' : '0');
  } else {
    settings[e.target.id] = Number(e.target.value);
    store(e.target.id, e.target.value);
  }
  if (e.target.id === 'smooth') aimFilters = null;
  showSettings();
  send();
});
document.getElementById('settings').addEventListener('click', () => { panel.hidden = false; });

// Installation (⚙), tant que la manette ne l'est pas : la fenêtre du navigateur quand il en a une (Chrome, Samsung,
// Edge sur Android), sinon le chemin à suivre (Safari sur iPhone, Firefox). Lu au chargement : le plein écran
// demandé par Connecter passerait pour une appli installée.
const installed = navigator.standalone || matchMedia('(display-mode: fullscreen), (display-mode: standalone)').matches;
const installButton = document.getElementById('install');
const installHint = document.getElementById('installHint');
const apple = /iPhone|iPad|iPod/.test(navigator.userAgent) || (/Macintosh/.test(navigator.userAgent) && navigator.maxTouchPoints > 1);
let installPrompt = null;
function showInstall() {
  installButton.hidden = installed || !installPrompt;
  installHint.hidden = installed || Boolean(installPrompt);
  installHint.textContent = apple
    ? "Pour l'installer : menu Partager de Safari, « Sur l'écran d'accueil », avec « Ouvrir en tant qu'app web » activé."
    : "Pour l'installer : menu du navigateur, puis « Installer l'application » ou « Ajouter à l'écran d'accueil ».";
}
showInstall();
addEventListener('beforeinstallprompt', (e) => {
  // Pas de bandeau du navigateur en pleine partie : seulement le bouton des réglages.
  e.preventDefault();
  installPrompt = e;
  showInstall();
});
installButton.addEventListener('click', () => {
  installPrompt?.prompt();
  installPrompt = null;
  showInstall();
});
document.getElementById('closeSettings').addEventListener('click', () => { panel.hidden = true; });

modeButton.addEventListener('click', () => {
  mode = mode === 'sideways' ? 'vertical' : 'sideways';
  hold = mode === 'sideways' ? 90 : 0;
  store('mode', mode);
  lockOrientation();
  layout();
});

function say(text) {
  status.textContent = text;
  overlay.hidden = false;
}

function send() {
  packet.setUint16(0, buttons, true);
  const out = steer !== null ? wheelMotion(steer * settings.stick)
    : mode === 'sideways' ? tiltGain(motion, settings.tilt)
    : motion;
  out.forEach((v, i) => packet.setFloat32(2 + 4 * i, v, true));
  packet.setUint16(26, aim[0], true);
  packet.setUint16(28, aim[1], true);
  if (direct) {
    // Numéro croissant (le serveur jette un datagramme doublé par un plus récent) et instant du téléphone.
    datagram.setUint32(0, ++direct.seq, true);
    datagram.setUint32(4, Math.round(performance.now()) >>> 0, true);
    new Uint8Array(datagram.buffer, 8).set(new Uint8Array(packet.buffer));
    direct.writer.write(new Uint8Array(datagram.buffer.slice(0))).catch(() => {});
    return;
  }
  if (ws?.readyState !== WebSocket.OPEN || ws.bufferedAmount > 1024) return;
  ws.send(packet.buffer);
}

// Pourquoi la liaison directe manque, pour les réglages.
let directIssue = 'WebTransport' in window ? '' : 'navigateur sans UDP (sur iPhone : iOS 26.4 minimum)';
function showLink() {
  document.getElementById('link').textContent = direct
    ? 'directe (UDP)'
    : `par Cloudflare (WebSocket)${directIssue && ` : ${directIssue}`}`;
}
showLink();

async function connectDirect(url) {
  if (!('WebTransport' in window)) return;
  directIssue = 'essai de la liaison directe…';
  showLink();
  try {
    const wt = new WebTransport(url);
    await wt.ready;
    // Safari n'a que createWritable(), qui remplace l'attribut writable dans la spec ; Chrome a encore writable.
    const datagrams = wt.datagrams.createWritable?.() ?? wt.datagrams.writable;
    direct = { wt, writer: datagrams.getWriter(), seq: 0 };
    directIssue = '';
    readPongs(wt.datagrams.readable);
    wt.closed.catch(() => {}).finally(() => {
      if (direct?.wt === wt) direct = null;
      showLink();
    });
  } catch (e) {
    // Liaison directe refusée ou injoignable (réseau qui bloque l'UDP) : on reste sur le WebSocket. L'erreur du
    // navigateur, telle quelle, aide à savoir pourquoi.
    directIssue = `liaison directe impossible (${e?.message || e})`;
  }
  showLink();
}

function closeDirect() {
  direct?.wt.close();
  direct = null;
  showLink();
}

// Délai (⚙) : une mesure datée par seconde sur la liaison en service, que le serveur renvoie telle quelle. Affiché :
// l'aller-retour (médiane des 5 dernières), et sa moitié, le délai d'un appui jusqu'au serveur.
const pingSize = 8;
const now32 = () => Math.round(performance.now()) >>> 0;
let roundTrips = [];
function pong(data) {
  if (data.byteLength !== pingSize) return;
  roundTrips = [...roundTrips.slice(-4), (now32() - new DataView(data.buffer ?? data, data.byteOffset ?? 0).getUint32(4, true)) >>> 0];
  const ms = [...roundTrips].sort((a, b) => a - b)[roundTrips.length >> 1];
  document.getElementById('delay').textContent = `≈ ${Math.round(ms / 2)} ms (aller-retour ${ms} ms)`;
}
async function readPongs(readable) {
  const reader = readable?.getReader();
  for (;;) {
    const { value, done } = (await reader?.read().catch(() => null)) ?? { done: true };
    if (done) return;
    pong(value);
  }
}
setInterval(() => {
  const ping = new DataView(new ArrayBuffer(pingSize));
  ping.setUint32(4, now32(), true);
  if (direct) direct.writer.write(new Uint8Array(ping.buffer)).catch(() => {});
  else if (ws?.readyState === WebSocket.OPEN) ws.send(ping.buffer);
}, 1000);

// Liaison directe active : le WebSocket ne porte plus rien, un signe de vie lui évite d'être coupé (2 s).
setInterval(() => {
  if (direct && ws?.readyState === WebSocket.OPEN) ws.send(new Uint8Array([0]));
}, 500);

const toU16 = (v) => Math.round((Math.max(-1, Math.min(1, v)) + 1) / 2 * 0xFFFF);

// Le téléphone vise lui-même, avec ses propres horodatages : rien ne s'accumule si le réseau hoquette, contrairement
// au pointeur que Dolphin tirerait du gyroscope reçu.
function updateAim(t) {
  const direction = pointer.direction(hold);
  if (mode !== 'vertical' || !tv || !direction) {
    aim = [AIM_CENTER, AIM_CENTER];
    aimFilters = null;
    return;
  }
  const raw = tv(recentre(direction));
  const preset = SMOOTHING[settings.smooth];
  aimFilters ??= raw.map(() => (preset ? oneEuro(preset) : (v) => v));
  aim = raw.map((v, i) => toU16(aimFilters[i](v, t)));
}

// Calibrage (⚙, ou ⌖ la première fois) : viser les coins de l'écran dans l'ordre (↖ ↗ ↘ ↙) en appuyant sur ⌖ à
// chacun. Ensuite, ⌖ recentre : viser le milieu de l'écran et appuyer.
const CORNERS = ['↖', '↗', '↘', '↙'];
function calibrate() {
  aimed = [];
  aimButton.textContent = `${CORNERS[0]} coin`;
}
aimButton.addEventListener('click', () => {
  const now = pointer.direction(hold);
  if (!now) return;
  if (!aimed) {
    if (!tv) return calibrate();
    recentre = ((fix, before) => (v) => fix(before(v)))(turnTo(recentre(now), tv.center), recentre);
    navigator.vibrate?.(20);
    return;
  }
  aimed.push(now);
  if (aimed.length < CORNERS.length) {
    aimButton.textContent = `${CORNERS[aimed.length]} coin`;
    return;
  }
  const calibrated = screenFrom(aimed);
  if (calibrated) {
    tv = calibrated;
    recentre = (v) => v;
    aimFilters = null;
    navigator.vibrate?.([20, 40, 20]);
  } else {
    // Coins confondus ou dans le désordre : calibrage refusé, l'ancien reste.
    navigator.vibrate?.(300);
  }
  aimed = null;
  aimButton.textContent = '⌖';
});
document.getElementById('calibrate').addEventListener('click', () => {
  panel.hidden = true;
  calibrate();
});

const dpad = document.querySelector('.dpad');

// Recalculé à chaque contact, pour tous les doigts à la fois. La croix se lit à l'angle du doigt (direction la plus
// proche), et le doigt la fait tourner en roulant dessus.
function refreshButtons() {
  const pressed = new Set();
  let next = 0;
  const box = dpad.getBoundingClientRect();
  let thumb = [0, 0];
  let wheel = null;
  for (const [id, finger] of pointers) {
    const { x, y } = finger;
    if (stickPointers.has(id)) {
      const box = joystick.getBoundingClientRect();
      const radius = box.width / 2;
      const origin = stickPointers.get(id) ?? { x: box.left + radius, y: box.top + radius };
      const [lx, ly] = toLocal(x - origin.x, y - origin.y, hold - liveAngle());
      const dirs = stickDirections(lx, ly, radius);
      const reach = radius * 0.6;
      if (control === 'wheel' && mode === 'sideways') {
        // Volant : la course horizontale braque, progressivement ; seul un coup de pouce vertical franc fait une
        // flèche (objets de Mario Kart), sans quoi un pouce qui dérive en virage lancerait l'objet.
        wheel = Math.abs(lx) < radius * 0.06 ? 0 : Math.max(-1, Math.min(1, lx / reach));
        flick = wheelItem(flick, ly, reach, performance.now());
        if (flick.item) next |= 1 << BIT[DPAD[mode][flick.item]];
      } else {
        for (const dir of dirs) next |= 1 << BIT[DPAD[mode][dir]];
      }
      // Le bouton suit le pouce, sans sortir du socle.
      const scale = Math.min(1, reach / (Math.hypot(lx, ly) || 1));
      thumb = [lx * scale, ly * scale];
      continue;
    }
    // Un doigt garde ce sur quoi il s'est posé (ou a glissé en premier) jusqu'à se lever, même s'il en sort : un
    // bouton reste appuyé, la croix continue de se lire à l'angle du doigt. Un bouton sous le doigt passe avant la
    // zone de la croix, plus large que son dessin.
    const dx = x - (box.left + box.width / 2);
    const dy = y - (box.top + box.height / 2);
    const rotation = hold - liveAngle();
    finger.on ??= document.elementFromPoint(x, y)?.closest('[data-btn]')
      ?? (control === 'dpad' && dpadDirection(dx, dy, box.width / 2, rotation) ? dpad : null);
    if (finger.on === dpad) {
      const dir = control === 'dpad' && dpadDirection(dx, dy, box.width / 2, rotation, Infinity);
      if (dir) {
        pressed.add(dpad.querySelector(`[data-dir="${dir}"]`));
        next |= 1 << BIT[DPAD[mode][dir]];
      }
    } else if (finger.on) {
      pressed.add(finger.on);
      next |= 1 << BIT[finger.on.dataset.btn];
    }
  }
  knob.style.transform = `translate(${thumb[0]}px, ${thumb[1]}px)`;
  for (const el of document.querySelectorAll('[data-btn], [data-dir]')) {
    el.classList.toggle('on', pressed.has(el));
  }
  const steered = wheel !== steer;
  steer = wheel;
  if (next === buttons) {
    if (steered) send();
    return;
  }
  if (next & ~buttons) navigator.vibrate?.(12);
  for (let b = 0; b < 16; b++) if (next & ~buttons & (1 << b)) presses[b]++;
  buttons = next;
  send();
}

const track = (e) => {
  // Même objet d'un mouvement à l'autre : il garde ce que le doigt tient (`on`).
  pointers.set(e.pointerId, Object.assign(pointers.get(e.pointerId) ?? {}, { x: e.clientX, y: e.clientY }));
  refreshButtons();
};
const untrack = (e) => {
  pointers.delete(e.pointerId);
  stickPointers.delete(e.pointerId);
  refreshButtons();
};
// Joystick : le pouce posé dessus (ou tout près) le garde jusqu'à ce qu'il se lève, même en débordant. Posé sur le
// bouton, il en devient le centre : un pouce posé un peu à côté ne fait pas dériver. Posé sur le bord, la direction
// compte aussitôt (coup franc du volant).
const stickPointers = new Map();
addEventListener('pointerdown', (e) => {
  // Panneau des réglages ouvert : la manette ne réagit pas.
  if (!panel.hidden) return;
  if (control !== 'dpad' && !document.elementFromPoint(e.clientX, e.clientY)?.closest('button')) {
    const box = joystick.getBoundingClientRect();
    const r = box.width / 2;
    const d = Math.hypot(e.clientX - (box.left + r), e.clientY - (box.top + r));
    if (d < r * 1.3) {
      stickPointers.set(e.pointerId, d < r * 0.4 ? { x: e.clientX, y: e.clientY } : null);
      // Pouce posé : le calme commence là (posé directement tout en haut, c'est un coup franc).
      flick = { calm: performance.now(), item: null };
    }
  }
  track(e);
});
addEventListener('pointermove', (e) => pointers.has(e.pointerId) && track(e));
addEventListener('pointerup', untrack);
addEventListener('pointercancel', untrack);
addEventListener('contextmenu', (e) => e.preventDefault());
// Filets : un doigt levé dont le navigateur n'a pas signalé la fin (geste du système, iOS) laissait un bouton ou le
// joystick enfoncé. Plus aucun doigt sur l'écran, ou la page quittée : tout est relâché.
function releaseAll() {
  pointers.clear();
  stickPointers.clear();
  refreshButtons();
}
for (const type of ['touchend', 'touchcancel']) addEventListener(type, (e) => e.touches.length === 0 && releaseAll());
addEventListener('blur', releaseAll);
document.addEventListener('visibilitychange', () => document.hidden && releaseAll());

addEventListener('deviceorientation', (e) => {
  if (e.beta === null) return;
  orientation = e;
});

addEventListener('devicemotion', (e) => {
  const r = e.rotationRate;
  if (r?.alpha != null) {
    pointer.update(r, e.timeStamp);
    updateAim(e.timeStamp);
  }
  const a = e.accelerationIncludingGravity;
  if (a?.x == null) return;

  if (samples < 30 && orientation) {
    const norm = Math.hypot(a.x, a.y, a.z);
    if (Math.abs(norm - G) < 1.5) {
      const up = upFromOrientation(orientation.beta, orientation.gamma);
      agreement += (a.x * up[0] + a.y * up[1] + a.z * up[2]) / norm;
      if (++samples === 30) accelSign = agreement < 0 ? -1 : 1;
    }
  }

  // Repère de la tenue, pas de l'écran : il ne change pas quand l'écran bascule.
  motion = toDSU(
    [a.x * accelSign, a.y * accelSign, a.z * accelSign],
    // rotationRate : x, y, z dans l'ordre alpha, beta, gamma (Chrome, Firefox, Safari).
    [r?.alpha ?? 0, r?.beta ?? 0, r?.gamma ?? 0],
    hold,
    mode === 'sideways',
  );
  send();
});

// Le serveur libère une manette muette depuis 2 s.
setInterval(send, 200);

function showPlayer(slot) {
  leds.forEach((led, i) => led.classList.toggle('on', i === slot));
}

// Lien d'invitation de l'hôte : le jeton est après « # », gardé pour les reconnexions puis retiré de l'adresse.
// Aussi sur `hashchange` : ouvert dans un onglet déjà sur la page, le lien ne la recharge pas.
function readInvite() {
  if (location.hash.length <= 1) return;
  store('invite', location.hash.slice(1));
  history.replaceState(null, '', location.pathname);
}
readInvite();
addEventListener('hashchange', () => {
  readInvite();
  if (ws?.readyState !== WebSocket.OPEN) idle();
});

let retry = true;
// Jeton de la session en cours, pour en reprendre la place après une coupure ou un rechargement de l'onglet ; début
// de la coupure (0 : aucune).
let session = '';
try {
  session = sessionStorage.getItem('session') ?? '';
} catch {}
function keepSession(token) {
  session = token;
  try {
    sessionStorage.setItem('session', token);
  } catch {}
}
let lost = 0;

function connect() {
  const scheme = location.protocol === 'https:' ? 'wss' : 'ws';
  ws = new WebSocket(`${scheme}://${location.host}/ws`);
  ws.binaryType = 'arraybuffer';
  ws.onopen = () => ws.send(JSON.stringify({ invite: store('invite') ?? '', name: nameInput.value.trim(), resume: session }));
  ws.onmessage = (e) => {
    if (typeof e.data !== 'string') return pong(e.data);
    const msg = JSON.parse(e.data);
    if (msg.error) {
      lastError = msg.error;
      retry = msg.retry;
      return;
    }
    lastError = '';
    if (msg.token) keepSession(msg.token);
    lost = 0;
    document.body.classList.remove('searching');
    showPlayer(msg.slot);
    if (msg.direct && !direct) connectDirect(msg.direct);
    overlay.hidden = true;
    navigator.vibrate?.([30, 60, 30]);
    send();
  };
  ws.onclose = () => {
    showPlayer(-1);
    closeDirect();
    if (retry) {
      // Coupure : reconnexion aussitôt, sa place reprise avec le jeton de session. La manette reste à l'écran, ses
      // diodes clignotent ; l'écran de connexion ne revient que si ça dure.
      lost ||= performance.now();
      const since = performance.now() - lost;
      if (lastError || since > 5000) say(lastError || 'Connexion perdue, nouvelle tentative…');
      else document.body.classList.add('searching');
      setTimeout(connect, since < 2000 ? 250 : 2500);
      return;
    }
    // Lien remplacé par l'hôte : on oublie l'ancien et on propose de scanner le nouveau.
    store('invite', '');
    retry = true;
    keepSession('');
    lost = 0;
    document.body.classList.remove('searching');
    idle(lastError);
  };
}

// Scanner le QR code de l'hôte dans l'appli : installée, elle ne reçoit pas le lien qu'ouvre l'appareil photo du
// téléphone (il part dans le navigateur). Le détecteur du navigateur s'il en a un (Chrome sur Android), sinon jsQR
// (Safari), chargé au premier scan.
const scanButton = document.getElementById('scan');
const camera = document.getElementById('camera');
const canScan = Boolean(navigator.mediaDevices?.getUserMedia);

async function qrReader() {
  if ('BarcodeDetector' in window) {
    const detector = new BarcodeDetector({ formats: ['qr_code'] });
    return async () => (await detector.detect(camera).catch(() => [])).map((code) => code.rawValue);
  }
  if (!window.jsQR) {
    await new Promise((resolve, reject) => {
      document.head.append(Object.assign(document.createElement('script'), { src: 'jsQR.js', onload: resolve, onerror: reject }));
    });
  }
  const canvas = document.createElement('canvas');
  const context = canvas.getContext('2d', { willReadFrequently: true });
  return async () => {
    // Image réduite : assez pour le QR code de l'hôte, et rapide même sur un vieux téléphone.
    const scale = Math.min(1, 640 / Math.max(camera.videoWidth, camera.videoHeight, 1));
    canvas.width = Math.round(camera.videoWidth * scale);
    canvas.height = Math.round(camera.videoHeight * scale);
    if (!canvas.width || !canvas.height) return [];
    context.drawImage(camera, 0, 0, canvas.width, canvas.height);
    const { data } = context.getImageData(0, 0, canvas.width, canvas.height);
    const code = window.jsQR(data, canvas.width, canvas.height, { inversionAttempts: 'dontInvert' });
    return code ? [code.data] : [];
  };
}

function idle(message) {
  const invited = Boolean(store('invite'));
  say(
    message ??
      (invited
        ? 'Tenue horizontale pour Mario Kart. Le bouton ⟲ en haut à droite passe à la verticale.'
        : `Scanne le QR code affiché sur la page de l'hôte${canScan ? '' : " avec l'appareil photo du téléphone"}.`),
  );
  startButton.hidden = !invited;
  nameInput.hidden = !invited;
  // Toujours là : un lien remplacé par l'hôte se rescanne sans quitter l'appli.
  scanButton.hidden = !canScan;
  scanButton.classList.toggle('quiet', invited);
}

function stopCamera() {
  camera.srcObject?.getTracks().forEach((track) => track.stop());
  camera.srcObject = null;
  camera.hidden = true;
  scanButton.textContent = 'Scanner le QR code';
}

scanButton.addEventListener('click', async () => {
  if (!camera.hidden) {
    stopCamera();
    return;
  }
  try {
    camera.srcObject = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' } });
  } catch {
    idle("Caméra refusée : scanne le QR code avec l'appareil photo du téléphone.");
    return;
  }
  camera.hidden = false;
  scanButton.textContent = 'Annuler';
  await camera.play().catch(() => {});
  let read;
  try {
    read = await qrReader();
  } catch {
    stopCamera();
    idle('Lecteur de QR code indisponible : recharge la page.');
    return;
  }
  while (!camera.hidden) {
    for (const rawValue of await read()) {
      const url = URL.canParse(rawValue) ? new URL(rawValue) : null;
      // Seulement un lien d'invitation de ce site : un autre QR code est ignoré.
      if (url?.origin === location.origin && url.hash.length > 1) {
        store('invite', url.hash.slice(1));
        stopCamera();
        navigator.vibrate?.(30);
        idle('Invitation reçue. Appuie sur Connecter.');
        return;
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
});

idle();

async function keepAwake() {
  if (document.visibilityState !== 'visible' || !navigator.wakeLock) return;
  wakeLock = await navigator.wakeLock.request('screen').catch(() => undefined);
}
document.addEventListener('visibilitychange', keepAwake);

// Prénom affiché à l'hôte sur /dolphin, gardé pour les prochaines fois.
nameInput.value = store('name') ?? '';
nameInput.addEventListener('input', () => store('name', nameInput.value));
nameInput.addEventListener('keydown', (e) => e.key === 'Enter' && startButton.click());

startButton.addEventListener('click', async () => {
  startButton.hidden = true;
  nameInput.hidden = true;
  nameInput.blur();
  say('Connexion…');
  // Tout dans le geste de l'utilisateur : iOS n'accorde les capteurs et Android le plein écran qu'ainsi.
  if (matchMedia('(display-mode: fullscreen), (display-mode: standalone)').matches) {
    lockOrientation();
  } else {
    document.documentElement.requestFullscreen?.().then(lockOrientation, () => {});
  }
  const asks = [DeviceMotionEvent, DeviceOrientationEvent]
    .filter((E) => typeof E?.requestPermission === 'function')
    .map((E) => E.requestPermission().catch(() => 'denied'));
  if ((await Promise.all(asks)).includes('denied')) {
    say('Mouvements refusés : autorisez-les dans les réglages du navigateur, puis rechargez la page.');
    startButton.hidden = false;
    return;
  }
  keepAwake();
  connect();
});
