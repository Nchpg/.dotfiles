import { gameTags, layoutFor } from './layouts.mjs';
import { G, gyroPointer, screenFrom, turnTo, dpadDirection, holdAngle, notOlder, oneEuro, stickDirections, tiltGain, toLocal, wheelMotion, wheelSteer, withShake, rumbleTail, toDSU, upFromOrientation } from './motion.mjs';

// Bit de chaque bouton dans le message : même ordre que `buttons` dans dsu.go. Secouer se fait en secouant le
// téléphone : l'accéléromètre part tel quel.
const BIT = { A: 0, B: 1, 1: 2, 2: 3, '-': 4, '+': 5, Home: 6, Up: 7, Down: 8, Left: 9, Right: 10 };

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
// Accélération hors gravité (g, repère DSU), pour garder les secousses quand le joystick braque (withShake).
let shake = [0, 0, 0];
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
// Version de la page chargée, lue au chargement. Le serveur annonce la sienne à chaque connexion : si elle diffère
// (serveur mis à jour depuis), la page se recharge et reprend sa place (jeton de session), au lieu de garder
// l'ancien code.
const loadedVersion = fetch('version', { cache: 'no-store' })
  .then((r) => (r.ok ? r.text() : ''))
  .catch(() => '');
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

// Croix ou joystick, au choix, mémorisé. Le joystick fait la croix, sauf en course de Mario Kart, où il devient le
// volant (layouts.mjs). L'ancienne valeur « wheel » est le joystick.
const CONTROLS = ['dpad', 'stick'];
let control = store('control') === 'wheel' ? 'stick' : CONTROLS.includes(store('control')) ? store('control') : 'dpad';
function showControl() {
  document.body.classList.toggle('stick', control === 'stick');
}
showControl();
document.getElementById('pad').addEventListener('click', () => {
  control = CONTROLS[(CONTROLS.indexOf(control) + 1) % CONTROLS.length];
  store('control', control);
  showControl();
});
// Volant tenu : position du joystick (−1 à 1), qui remplace l'inclinaison ; null : l'inclinaison reprend.
let steer = null;
// Accélération automatique (de côté) : 2 reste enfoncé sans le pouce, libre pour B (l'objet, en dérapage
// automatique). En course seulement (layouts.mjs : dans les menus, un 2 toujours tenu validerait sans fin) : 2
// appuyé, un cadenas apparaît à sa droite, et y glisser le doigt verrouille 2, qui reste enfoncé une fois lâché.
// Seul un nouvel appui sur 2 ou 1 l'éteint, avec la fin de la course, le passage à la verticale et la page quittée :
// lever tous les doigts ou changer croix/joystick le garde.
let cruise = false;
const twoButton = document.querySelector('[data-btn="2"]');
// Glissé qui verrouille : vers la droite de la manette, de plus de la moitié de la largeur de 2.
const CRUISE_SLIDE = 0.5;
const CRUISE_STOP = (1 << BIT[2]) | (1 << BIT[1]);
// En course, on tient 1 ou 2 : le joystick braque. Sinon (menus), il fait la croix, comme les flèches.
const RACING = (1 << BIT[1]) | (1 << BIT[2]);
// Boutons tenus par les doigts seuls, au dernier passage : un nouvel appui éteint l'accélération automatique.
let fingers = 0;

// Disposition du jeu en cours (layouts.mjs), appliquée quand aucun doigt ne touche l'écran : un bouton ne se déplace
// pas sous le pouce. Le verrou, lui, lâche 2 dès la fin de la course, pour ne pas valider sans fin les menus.
let gameLayout = layoutFor([]);
let wantedLayout = gameLayout;
function showGame(game, stage) {
  wantedLayout = layoutFor(gameTags(game, stage));
  if (!wantedLayout.verrou) cruise = false;
  applyLayout();
  refreshButtons();
}
function applyLayout() {
  if (pointers.size || gameLayout === wantedLayout) return;
  gameLayout = wantedLayout;
  document.body.classList.toggle('volant', Boolean(gameLayout.volant));
  document.body.classList.toggle('verrou', Boolean(gameLayout.verrou));
  modeButton.disabled = Boolean(gameLayout.horizontal);
  if (gameLayout.horizontal && mode !== 'sideways') setMode('sideways');
}

// Réglages du panneau ⚙, mémorisés : B à côté de A, vibrations, sensibilités de l'inclinaison et du joystick volant.
const panel = document.getElementById('panel');
const gain = (key) => Math.min(2, Math.max(0.5, Number(store(key)) || 1));
const settings = {
  bByA: store('bByA') === '1',
  // ms de vibration par période de 20 (cf. rumblePattern), 10 par défaut. L'ancien niveau (0 à 3) est repris.
  rumble:
    store('rumble') !== null
      ? Math.min(20, Math.max(0, Math.round(Number(store('rumble'))) || 0))
      : ([0, 10, 15, 20][Number(store('vibrate') ?? 1)] ?? 10),
  // Traîne des vibrations (ms, cf. rumbleTail) : l'inertie du moteur d'une Wiimote. 0 : coupure nette.
  tail: store('tail') !== null ? Math.min(150, Math.max(0, Math.round(Number(store('tail'))) || 0)) : 50,
  showLag: store('showLag') === '1',
  tilt: gain('tilt'),
  stick: gain('stick'),
  smooth: Math.min(3, Math.max(0, Math.round(Number(store('smooth')) || 0))),
};
const times = (k) => `×${k.toFixed(1).replace('.', ',')}`;
// Vibrations du jeu, au choix, comme celles d'une vraie Wiimote : rien d'autre ne fait vibrer. Sans
// navigator.vibrate (iPhone : Safari n'a rien qui vibre sans un toucher depuis iOS 26.5), le réglage n'apparaît pas.
for (const id of ['vibrateRow', 'tailRow']) document.getElementById(id).hidden = !('vibrate' in navigator);
const rumbleLabel = (on) => (on <= 0 ? 'coupées' : on >= 20 ? 'continues' : `${on} ms sur 20`);
const tailLabel = (ms) => (ms <= 0 ? 'aucune' : `${ms} ms`);
// Vibration demandée par le jeu (Dolphin, par le serveur), tant qu'elle dure, puis sa traîne (rumbleTail). À l'arrêt,
// elle dure ce qu'elle a duré dans le jeu (`ms`, mesuré par le serveur), même si le réseau a livré le début et la fin
// ensemble. La Wiimote n'a qu'un moteur, tout ou rien. Le motif est renouvelé toutes les RUMBLE_TICK ms pour
// RUMBLE_HORIZON ms : même si le téléphone ignorait l'arrêt, la vibration ne déborderait pas plus.
const RUMBLE_TICK = 40;
const RUMBLE_HORIZON = 80;
let rumbleGrid = 0;
let rumbleSince = 0;
let rumbleOff = 0;
let rumbleTimer = null;
function rumble(level, ms = 0) {
  if (!settings.rumble || !('vibrate' in navigator)) return;
  const now = performance.now();
  if (level) {
    if (!rumbleTimer) rumbleGrid = now;
    if (rumbleOff !== Infinity) rumbleSince = now;
    rumbleOff = Infinity;
  } else if (rumbleOff === Infinity) {
    rumbleOff = Math.max(now, rumbleSince + ms);
  } else {
    return;
  }
  playRumble();
}
function playRumble() {
  clearTimeout(rumbleTimer);
  const pattern = rumbleTail(settings.rumble, settings.tail, rumbleOff, performance.now(), rumbleGrid, RUMBLE_HORIZON);
  if (!pattern) {
    rumbleTimer = null;
    return navigator.vibrate(0);
  }
  rumbleTimer = setTimeout(playRumble, RUMBLE_TICK);
  return navigator.vibrate(pattern);
}
// Tester : une rafale comme celles de Mario Kart (8 impulsions de 20 ms toutes les 120 ms), à la force et à la
// traîne choisies. « Bloqué » : le navigateur refuse ; « Envoyé » sans que rien ne vibre : un réglage du téléphone
// (vibrations coupées, mode silencieux).
const vibrateTest = document.getElementById('vibrateTest');
vibrateTest.addEventListener('click', () => {
  if (!settings.rumble) {
    vibrateTest.textContent = 'Coupées';
  } else {
    rumble(255);
    vibrateTest.textContent = rumbleTimer ? 'Envoyé' : 'Bloqué';
    for (let i = 0; i < 8; i++) {
      if (i) setTimeout(rumble, 120 * i, 255);
      setTimeout(rumble, 120 * i + 20, 0, 20);
    }
  }
  setTimeout(() => {
    vibrateTest.textContent = 'Tester';
  }, 1500);
});
// Message de vibration du serveur, par la liaison directe (renvoyé toutes les 200 ms) ou le WebSocket : le
// numéro du changement écarte un datagramme arrivé en retard ; un renvoi ne change rien.
let rumbleSeq = null;
function rumbleMessage(level, seq, ms) {
  if (!notOlder(seq, rumbleSeq)) return;
  rumbleSeq = seq;
  rumble(level, ms);
}
function showSettings() {
  document.getElementById('bByA').checked = settings.bByA;
  document.getElementById('rumble').value = settings.rumble;
  document.getElementById('rumbleOut').textContent = rumbleLabel(settings.rumble);
  document.getElementById('tail').value = settings.tail;
  document.getElementById('tailOut').textContent = tailLabel(settings.tail);
  document.getElementById('showLag').checked = settings.showLag;
  document.getElementById('lag').hidden = !settings.showLag;
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
  if (e.target.id === 'rumble') rumble(0);
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
    ? "Pour l'installer : Partager, puis « Sur l'écran d'accueil »."
    : "Pour l'installer : menu du navigateur, puis « Ajouter à l'écran d'accueil ».";
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
// Toucher à côté du panneau le ferme aussi.
panel.addEventListener('click', (e) => e.target === panel && (panel.hidden = true));

function setMode(next) {
  mode = next;
  hold = mode === 'sideways' ? 90 : 0;
  cruise = false;
  store('mode', mode);
  lockOrientation();
  layout();
}
modeButton.addEventListener('click', () => setMode(mode === 'sideways' ? 'vertical' : 'sideways'));

function say(text) {
  status.textContent = text;
  overlay.hidden = false;
}

function send() {
  packet.setUint16(0, buttons, true);
  const out = steer !== null ? withShake(wheelMotion(steer * settings.stick), shake)
    : mode === 'sideways' ? tiltGain(motion, settings.tilt)
    : motion;
  out.forEach((v, i) => packet.setFloat32(2 + 4 * i, v, true));
  packet.setUint16(26, aim[0], true);
  packet.setUint16(28, aim[1], true);
  if (direct) {
    // Réseau qui n'écoule pas tout (4G chargée : QUIC y ralentit l'envoi) : on saute cet état plutôt que de l'empiler
    // derrière les autres, ce qui retardait tout de plus d'une seconde. Le suivant le remplace, avec le compte des
    // appuis : aucun ne se perd.
    if (direct.pending >= 2) return;
    // Numéro croissant (le serveur jette un datagramme doublé par un plus récent) et instant du téléphone.
    datagram.setUint32(0, ++direct.seq, true);
    datagram.setUint32(4, Math.round(performance.now()) >>> 0, true);
    new Uint8Array(datagram.buffer, 8).set(new Uint8Array(packet.buffer));
    const link = direct;
    link.pending++;
    link.writer.write(new Uint8Array(datagram.buffer.slice(0))).catch(() => {}).finally(() => link.pending--);
    return;
  }
  if (ws?.readyState !== WebSocket.OPEN || ws.bufferedAmount > 1024) return;
  ws.send(packet.buffer);
}

// Pourquoi la liaison directe manque, pour les réglages.
let directIssue = 'WebTransport' in window ? '' : 'sans UDP';
function showLink() {
  document.getElementById('link').textContent = direct ? 'directe' : `Cloudflare${directIssue && ` (${directIssue})`}`;
}
showLink();

// Liaison directe perdue ou refusée en cours de session : on la retente, 1 s après puis en doublant l'écart jusqu'à
// 10 s, sans quoi la manette resterait par Cloudflare jusqu'à la prochaine reconnexion. `directURL` : celle de la
// session en cours (null : aucune, plus de nouvel essai).
let directURL = null;
let directTrying = false;
let directRetry = null;
let directDelay = 1000;
function retryDirect() {
  clearTimeout(directRetry);
  if (!directURL || direct) return;
  directRetry = setTimeout(() => {
    if (directURL && !direct && !directTrying && ws?.readyState === WebSocket.OPEN) connectDirect(directURL);
  }, directDelay);
  directDelay = Math.min(directDelay * 2, 10000);
}

async function connectDirect(url) {
  if (!('WebTransport' in window) || directTrying) return;
  directTrying = true;
  directIssue = 'essai du direct…';
  showLink();
  try {
    const wt = new WebTransport(url);
    await wt.ready;
    // Safari n'a que createWritable(), qui remplace l'attribut writable dans la spec ; Chrome a encore writable.
    // Dans la file du navigateur aussi : un datagramme qui attend depuis plus de 100 ms est jeté, le suivant est plus
    // frais.
    if ('outgoingMaxAge' in wt.datagrams) wt.datagrams.outgoingMaxAge = 100;
    const datagrams = wt.datagrams.createWritable?.() ?? wt.datagrams.writable;
    direct = { wt, writer: datagrams.getWriter(), seq: 0, pending: 0 };
    directIssue = '';
    directDelay = 1000;
    readDatagrams(wt.datagrams.readable);
    wt.closed.catch(() => {}).finally(() => {
      if (direct?.wt !== wt) return;
      direct = null;
      showLink();
      retryDirect();
    });
  } catch (e) {
    // Liaison directe refusée ou injoignable (réseau qui bloque l'UDP) : par le WebSocket en attendant le prochain essai.
    console.warn('liaison directe', e);
    directIssue = 'UDP impossible';
    retryDirect();
  } finally {
    directTrying = false;
  }
  showLink();
}

// Fin de la session : plus de liaison directe, ni de nouvel essai.
function closeDirect() {
  directURL = null;
  clearTimeout(directRetry);
  directDelay = 1000;
  direct?.wt.close();
  direct = null;
  showLink();
}

// Délai (⚙) : une mesure datée par seconde sur la liaison en service, que le serveur renvoie, suivie de son trajet
// jusqu'à Dolphin (µs, qu'il mesure lui-même ; 0 : inconnu). Affichés : la moitié de l'aller-retour (médiane des 5
// dernières), le délai d'un appui jusqu'au serveur, puis jusqu'à Dolphin.
const pingSize = 8;
const now32 = () => Math.round(performance.now()) >>> 0;
let roundTrips = [];
let lastPong = 0;
// Dernier aller-retour mesuré (ms, 0 : aucun), glissé dans chaque mesure pour le journal du serveur.
let lastRoundTrip = 0;
function pong(data) {
  if (data.byteLength < pingSize) return;
  const view = new DataView(data.buffer ?? data, data.byteOffset ?? 0, data.byteLength);
  lastPong = performance.now();
  roundTrips = [...roundTrips.slice(-4), (now32() - view.getUint32(4, true)) >>> 0];
  const ms = [...roundTrips].sort((a, b) => a - b)[roundTrips.length >> 1];
  lastRoundTrip = ms;
  const dolphin = data.byteLength >= pingSize + 4 ? view.getUint32(pingSize, true) / 1000 : 0;
  showDelay(Math.round(ms / 2), dolphin ? Math.round(dolphin) : null);
}
// Délai d'un appui jusqu'au serveur (la moitié de l'aller-retour), puis du serveur jusqu'à Dolphin, séparés pour
// voir lequel traîne, dans les réglages et sur la manette ; la couleur suit le total : vert jusqu'à 40 ms, orange
// jusqu'à 80, rouge au-delà ou sans réponse.
function showDelay(oneWay, dolphin = null) {
  const total = oneWay === null ? null : oneWay + (dolphin ?? 0);
  document.getElementById('delay').textContent =
    oneWay === null ? 'sans réponse'
      : dolphin === null ? `≈ ${oneWay} ms jusqu'au serveur`
        : `≈ ${oneWay} ms jusqu'au serveur + ${dolphin} ms jusqu'à Dolphin = ${total} ms`;
  const lag = document.getElementById('lag');
  lag.textContent = oneWay === null ? '—' : dolphin === null ? `${oneWay} ms` : `${oneWay} + ${dolphin} ms`;
  lag.className = `lag ${total === null || total > 80 ? 'bad' : total > 40 ? 'fair' : 'good'}`;
}
// Datagrammes du serveur : mesures du délai renvoyées (8 octets), vibrations (4 : niveau, numéro, durée en ms).
async function readDatagrams(readable) {
  const reader = readable?.getReader();
  for (;;) {
    const { value, done } = (await reader?.read().catch(() => null)) ?? { done: true };
    if (done) return;
    if (value.byteLength === 4) rumbleMessage(value[0], value[1], value[2] | (value[3] << 8));
    else pong(value);
  }
}
setInterval(() => {
  if (roundTrips.length && performance.now() - lastPong > 3000) {
    roundTrips = [];
    lastRoundTrip = 0;
    showDelay(null);
  }
  const ping = new DataView(new ArrayBuffer(pingSize));
  ping.setUint32(0, lastRoundTrip, true);
  ping.setUint32(4, now32(), true);
  if (direct) direct.writer.write(new Uint8Array(ping.buffer)).catch(() => {});
  else if (ws?.readyState === WebSocket.OPEN) ws.send(ping.buffer);
}, 1000);

// Liaison directe active : le WebSocket ne porte presque plus rien. Un signe de vie le garde ouvert : nginx coupe un
// WebSocket muet au bout de 60 s, Cloudflare au bout de 100 s. Le serveur, lui, suit les deux liaisons.
setInterval(() => {
  if (direct && ws?.readyState === WebSocket.OPEN) ws.send(new Uint8Array([0]));
}, 15000);

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
  aimButton.textContent = `Vise ${CORNERS[0]}`;
}
aimButton.addEventListener('click', () => {
  const now = pointer.direction(hold);
  if (!now) return;
  if (!aimed) {
    if (!tv) return calibrate();
    recentre = ((fix, before) => (v) => fix(before(v)))(turnTo(recentre(now), tv.center), recentre);
    return;
  }
  aimed.push(now);
  if (aimed.length < CORNERS.length) {
    aimButton.textContent = `Vise ${CORNERS[aimed.length]}`;
    return;
  }
  const calibrated = screenFrom(aimed);
  if (calibrated) {
    tv = calibrated;
    recentre = (v) => v;
    aimFilters = null;
  }
  // Coins confondus ou dans le désordre : calibrage refusé, l'ancien reste. Affiché un instant sur ⌖.
  aimed = null;
  aimButton.textContent = calibrated ? '✓' : '✗';
  setTimeout(() => {
    if (!aimed) aimButton.textContent = '⌖';
  }, 1000);
});
document.getElementById('calibrate').addEventListener('click', () => {
  panel.hidden = true;
  calibrate();
});

const dpad = document.querySelector('.dpad');
const itemButton = document.getElementById('item');

// Recalculé à chaque contact, pour tous les doigts à la fois. La croix se lit à l'angle du doigt (direction la plus
// proche), et le doigt la fait tourner en roulant dessus.
function refreshButtons() {
  const pressed = new Set();
  let next = 0;
  const box = dpad.getBoundingClientRect();
  let thumb = [0, 0];
  let wheel = null;
  // Les doigts sur les boutons d'abord : la course (1 ou 2 tenu) décide de ce que fait le joystick, et le joystick
  // du sens du bouton Objet.
  const thumbs = [];
  const itemFingers = [];
  let back = false;
  let slidToLock = false;
  let twoHeld = false;
  for (const [id, finger] of pointers) {
    if (stickPointers.has(id)) {
      thumbs.push([id, finger]);
      continue;
    }
    const { x, y } = finger;
    // Un doigt garde ce sur quoi il s'est posé (ou a glissé en premier) jusqu'à se lever, même s'il en sort : un
    // bouton reste appuyé, la croix continue de se lire à l'angle du doigt. Un bouton sous le doigt passe avant la
    // zone de la croix, plus large que son dessin.
    const dx = x - (box.left + box.width / 2);
    const dy = y - (box.top + box.height / 2);
    const rotation = hold - liveAngle();
    finger.on ??= document.elementFromPoint(x, y)?.closest('[data-btn], [data-item]')
      ?? (control === 'dpad' && dpadDirection(dx, dy, box.width / 2, rotation) ? dpad : null);
    if (finger.on === itemButton) {
      pressed.add(itemButton);
      itemFingers.push(finger);
    } else if (finger.on === dpad) {
      const dir = control === 'dpad' && dpadDirection(dx, dy, box.width / 2, rotation, Infinity);
      if (dir) {
        pressed.add(dpad.querySelector(`[data-dir="${dir}"]`));
        next |= 1 << BIT[DPAD[mode][dir]];
      }
    } else if (finger.on) {
      pressed.add(finger.on);
      next |= 1 << BIT[finger.on.dataset.btn];
      if (finger.on === twoButton) {
        twoHeld = true;
        // Une fois par doigt : glissé vers le cadenas.
        finger.start ??= { x, y };
        const [lx] = toLocal(x - finger.start.x, y - finger.start.y, rotation);
        if (!finger.slid && lx > twoButton.offsetWidth * CRUISE_SLIDE) {
          finger.slid = true;
          slidToLock = true;
        }
      }
    }
  }
  if (cruise && next & ~fingers & CRUISE_STOP) cruise = false;
  if (slidToLock && gameLayout.verrou && mode === 'sideways') cruise = true;
  fingers = next;
  if (cruise) {
    next |= 1 << BIT[2];
    pressed.add(twoButton);
  }
  document.body.classList.toggle('cruise', cruise);
  // Le cadenas à droite de 2 seulement sous le doigt : verrouillé et lâché, les réglages restent accessibles.
  document.body.classList.toggle('lock-shown', Boolean(gameLayout.verrou) && mode === 'sideways' && twoHeld);
  const racing = (next & RACING) !== 0;
  for (const [id, { x, y }] of thumbs) {
    const box = joystick.getBoundingClientRect();
    const radius = box.width / 2;
    const origin = stickPointers.get(id) ?? { x: box.left + radius, y: box.top + radius };
    const [lx, ly] = toLocal(x - origin.x, y - origin.y, hold - liveAngle());
    const reach = radius * 0.6;
    // Tiré vers soi (vers le bas) : le bouton Objet lance derrière.
    if (ly > reach * 0.5) back = true;
    if (mode === 'sideways' && gameLayout.volant && racing) {
      // Volant : la course horizontale braque, progressivement ; la verticale ne fait rien, les objets passent par
      // le bouton Objet.
      wheel = wheelSteer(lx, reach);
    } else {
      // Hors course, debout, ou en pause (ni 1 ni 2 tenu) : le joystick fait la croix.
      for (const dir of stickDirections(lx, ly, radius)) next |= 1 << BIT[DPAD[mode][dir]];
    }
    // Le bouton suit le pouce, sans sortir du socle.
    const scale = Math.min(1, reach / (Math.hypot(lx, ly) || 1));
    thumb = [lx * scale, ly * scale];
  }
  // Bouton Objet (mode volant) : une flèche de la croix, comme sur la Wiimote à l'horizontale. Devant, ou derrière si
  // le joystick est tiré vers soi au moment de l'appui, gardée jusqu'au relâché (banane tenue derrière soi).
  for (const finger of itemFingers) {
    finger.item ??= back ? 'down' : 'up';
    next |= 1 << BIT[DPAD[mode][finger.item]];
  }
  knob.style.transform = `translate(${thumb[0]}px, ${thumb[1]}px)`;
  for (const el of document.querySelectorAll('[data-btn], [data-dir], [data-item]')) {
    el.classList.toggle('on', pressed.has(el));
  }
  const steered = wheel !== steer;
  steer = wheel;
  if (next === buttons) {
    if (steered) send();
    return;
  }
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
  applyLayout();
  refreshButtons();
};
// Joystick : le pouce posé dessus (ou tout près) le garde jusqu'à ce qu'il se lève, même en débordant. Posé sur le
// bouton, il en devient le centre : un pouce posé un peu à côté ne fait pas dériver. Posé sur le bord, la direction
// compte aussitôt.
const stickPointers = new Map();
addEventListener('pointerdown', (e) => {
  // Panneau des réglages ouvert : la manette ne réagit pas.
  if (!panel.hidden) return;
  if (control === 'stick' && !document.elementFromPoint(e.clientX, e.clientY)?.closest('button')) {
    const box = joystick.getBoundingClientRect();
    const r = box.width / 2;
    const d = Math.hypot(e.clientX - (box.left + r), e.clientY - (box.top + r));
    if (d < r * 1.3) {
      stickPointers.set(e.pointerId, d < r * 0.4 ? { x: e.clientX, y: e.clientY } : null);
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
  applyLayout();
  refreshButtons();
}
// Page quittée : le verrou aussi.
function leave() {
  cruise = false;
  releaseAll();
}
for (const type of ['touchend', 'touchcancel']) addEventListener(type, (e) => e.touches.length === 0 && releaseAll());
addEventListener('blur', leave);
document.addEventListener('visibilitychange', () => document.hidden && leave());

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
  // Sans gyroscope, le navigateur ne la donne pas : pas de secousse au joystick, comme avant.
  const l = e.acceleration;
  shake = l?.x == null ? [0, 0, 0]
    : toDSU([l.x * accelSign, l.y * accelSign, l.z * accelSign], [0, 0, 0], hold, mode === 'sideways').slice(0, 3);
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
    if ('rumble' in msg) return rumbleMessage(msg.rumble, msg.seq, msg.ms);
    // Jeu en cours : dans l'accueil, puis à chaque changement.
    if ('game' in msg) showGame(msg.game, msg.stage);
    if (!('slot' in msg) && !msg.error) return;
    if (msg.error) {
      lastError = msg.error;
      retry = msg.retry;
      return;
    }
    lastError = '';
    if (msg.token) keepSession(msg.token);
    if (msg.version) loadedVersion.then((v) => v && v !== msg.version && location.reload());
    lost = 0;
    document.body.classList.remove('searching');
    showPlayer(msg.slot);
    if (msg.direct) {
      directURL = msg.direct;
      if (!direct) connectDirect(msg.direct);
    }
    overlay.hidden = true;
    send();
  };
  ws.onclose = () => {
    rumble(0);
    // Nouvelle session : ses numéros repartent de zéro.
    rumbleSeq = null;
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
const viewfinder = document.getElementById('viewfinder');
const camera = document.getElementById('camera');
const canScan = Boolean(navigator.mediaDevices?.getUserMedia);

// Zoom, pour scanner de loin : celui de la caméra quand elle en a un (Chrome sur Android, vraie définition), sinon
// numérique : l'image agrandie à l'écran, et seul son centre analysé, en pleine définition.
const zoom = document.getElementById('zoom');
let lens = null;
const digitalZoom = () => (lens ? 1 : Number(zoom.value));
zoom.addEventListener('input', () => {
  if (lens) lens.applyConstraints({ advanced: [{ zoom: Number(zoom.value) }] }).catch(() => {});
  else camera.style.setProperty('--zoom', zoom.value);
});

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
    // Le centre que montre le zoom, réduit à 640 px au plus : assez pour le QR code de l'hôte, et rapide même sur un
    // vieux téléphone.
    const z = digitalZoom();
    const [w, h] = [camera.videoWidth / z, camera.videoHeight / z];
    const scale = Math.min(1, 640 / Math.max(w, h, 1));
    canvas.width = Math.round(w * scale);
    canvas.height = Math.round(h * scale);
    if (!canvas.width || !canvas.height) return [];
    context.drawImage(camera, (camera.videoWidth - w) / 2, (camera.videoHeight - h) / 2, w, h, 0, 0, canvas.width, canvas.height);
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
  viewfinder.hidden = true;
  scanButton.textContent = 'Scanner le QR code';
}

scanButton.addEventListener('click', async () => {
  if (!viewfinder.hidden) {
    stopCamera();
    return;
  }
  try {
    // En haute définition : le zoom numérique a de quoi agrandir.
    camera.srcObject = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: 'environment', width: { ideal: 1920 }, height: { ideal: 1080 } },
    });
  } catch {
    idle("Caméra refusée : scanne le QR code avec l'appareil photo du téléphone.");
    return;
  }
  const [track] = camera.srcObject.getVideoTracks();
  const range = track?.getCapabilities?.().zoom;
  lens = range ? track : null;
  Object.assign(zoom, { min: range?.min ?? 1, max: range ? Math.min(range.max, 10) : 4, step: range?.step || 0.1 });
  zoom.value = zoom.min;
  camera.style.setProperty('--zoom', 1);
  viewfinder.hidden = false;
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
  while (!viewfinder.hidden) {
    for (const rawValue of await read()) {
      const url = URL.canParse(rawValue) ? new URL(rawValue) : null;
      // Seulement un lien d'invitation de ce site : un autre QR code est ignoré.
      if (url?.origin === location.origin && url.hash.length > 1) {
        store('invite', url.hash.slice(1));
        stopCamera();
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
