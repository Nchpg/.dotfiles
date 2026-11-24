import { G, aimAngles, aimPosition, dpadDirection, holdAngle, stickDirections, tiltGain, toLocal, wheelItem, wheelMotion, toDSU, upFromOrientation, validCorners } from './motion.mjs';

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
const packet = new DataView(new ArrayBuffer(28));
let buttons = 0;
let motion = [0, -1, 0, 0, 0, 0];
// Pointeur envoyé sur le stick droit (128 : centre), calé par le calibrage du bouton ⌖.
let aim = [128, 128];
let corners;
let firstCorner;
let ws;
let lastError = '';
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
  stage.style.width = `${turned ? innerHeight : innerWidth}px`;
  stage.style.height = `${turned ? innerWidth : innerHeight}px`;
  stage.style.transform = `translate(-50%, -50%) rotate(${hold - live}deg)`;
  document.body.classList.toggle('sideways', mode === 'sideways');
}
addEventListener('resize', layout);
screen.orientation?.addEventListener('change', layout);
layout();

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
const settings = { bByA: store('bByA') === '1', tilt: gain('tilt'), stick: gain('stick') };
const times = (k) => `×${k.toFixed(1).replace('.', ',')}`;
function showSettings() {
  document.getElementById('bByA').checked = settings.bByA;
  document.body.classList.toggle('b-by-a', settings.bByA);
  for (const key of ['tilt', 'stick']) {
    document.getElementById(key).value = settings[key];
    document.getElementById(`${key}Out`).textContent = times(settings[key]);
  }
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
  showSettings();
  send();
});
document.getElementById('settings').addEventListener('click', () => { panel.hidden = false; });
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
  if (ws?.readyState !== WebSocket.OPEN || ws.bufferedAmount > 1024) return;
  packet.setUint16(0, buttons, true);
  const out = steer !== null ? wheelMotion(steer * settings.stick)
    : mode === 'sideways' ? tiltGain(motion, settings.tilt)
    : motion;
  out.forEach((v, i) => packet.setFloat32(2 + 4 * i, v, true));
  packet.setUint8(26, aim[0]);
  packet.setUint8(27, aim[1]);
  ws.send(packet.buffer);
}

const toByte = (v) => Math.round(128 + v * 127);

// Le téléphone vise lui-même, d'après l'orientation que fusionne son système : rien ne s'accumule si le
// réseau hoquette, contrairement au pointeur que Dolphin tirerait du gyroscope.
function updateAim() {
  if (mode !== 'vertical' || !corners || orientation?.alpha == null) {
    aim = [128, 128];
    return;
  }
  const [x, y] = aimPosition(aimAngles(orientation.alpha, orientation.beta, hold), ...corners);
  aim = [toByte(x), toByte(y)];
}

// ⌖, puis viser le coin haut gauche de l'écran et appuyer, puis le coin bas droit et appuyer.
aimButton.addEventListener('click', () => {
  if (orientation?.alpha == null) return;
  const now = aimAngles(orientation.alpha, orientation.beta, hold);
  if (aimButton.dataset.step === 'top-left') {
    firstCorner = now;
    aimButton.dataset.step = 'bottom-right';
    aimButton.textContent = '↘ coin';
    return;
  }
  if (aimButton.dataset.step === 'bottom-right' && validCorners(firstCorner, now)) {
    corners = [firstCorner, now];
    navigator.vibrate?.([20, 40, 20]);
  }
  const start = !aimButton.dataset.step;
  aimButton.dataset.step = start ? 'top-left' : '';
  aimButton.textContent = start ? '↖ coin' : '⌖';
});

const dpad = document.querySelector('.dpad');

// Recalculé à chaque contact : glisser d'un bouton à l'autre et appuyer à plusieurs doigts marchent.
// La croix se lit à l'angle du doigt (direction la plus proche, zone plus large que son dessin) ; un autre
// bouton sous le doigt garde la priorité.
function refreshButtons() {
  const pressed = new Set();
  let next = 0;
  const box = dpad.getBoundingClientRect();
  let thumb = [0, 0];
  let wheel = null;
  for (const [id, { x, y }] of pointers) {
    const el = document.elementFromPoint(x, y)?.closest('[data-btn]');
    if (el && !stickPointers.has(id)) {
      pressed.add(el);
      next |= 1 << BIT[el.dataset.btn];
      continue;
    }
    if (stickPointers.has(id)) {
      const box = joystick.getBoundingClientRect();
      const radius = box.width / 2;
      const [lx, ly] = toLocal(x - (box.left + radius), y - (box.top + radius), hold - liveAngle());
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
    if (control !== 'dpad') continue;
    const dir = dpadDirection(
      x - (box.left + box.width / 2),
      y - (box.top + box.height / 2),
      box.width / 2,
      hold - liveAngle(),
    );
    if (dir) {
      pressed.add(dpad.querySelector(`[data-dir="${dir}"]`));
      next |= 1 << BIT[DPAD[mode][dir]];
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
  buttons = next;
  send();
}

const track = (e) => {
  pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
  refreshButtons();
};
const untrack = (e) => {
  pointers.delete(e.pointerId);
  stickPointers.delete(e.pointerId);
  refreshButtons();
};
// Joystick : le pouce posé dessus (ou tout près) le garde jusqu'à ce qu'il se lève, même en débordant.
const stickPointers = new Set();
addEventListener('pointerdown', (e) => {
  // Panneau des réglages ouvert : la manette ne réagit pas.
  if (!panel.hidden) return;
  if (control !== 'dpad' && !document.elementFromPoint(e.clientX, e.clientY)?.closest('button')) {
    const box = joystick.getBoundingClientRect();
    const r = box.width / 2;
    if (Math.hypot(e.clientX - (box.left + r), e.clientY - (box.top + r)) < r * 1.3) {
      stickPointers.add(e.pointerId);
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

addEventListener('deviceorientation', (e) => {
  if (e.beta === null) return;
  orientation = e;
  updateAim();
});

addEventListener('devicemotion', (e) => {
  const a = e.accelerationIncludingGravity;
  if (a?.x == null) return;
  const r = e.rotationRate;

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
    [r?.beta ?? 0, r?.gamma ?? 0, r?.alpha ?? 0],
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

function connect() {
  const scheme = location.protocol === 'https:' ? 'wss' : 'ws';
  ws = new WebSocket(`${scheme}://${location.host}/ws`);
  ws.onopen = () => ws.send(JSON.stringify({ invite: store('invite') ?? '', name: nameInput.value.trim() }));
  ws.onmessage = (e) => {
    if (typeof e.data !== 'string') return;
    const msg = JSON.parse(e.data);
    if (msg.error) {
      lastError = msg.error;
      retry = msg.retry;
      return;
    }
    lastError = '';
    showPlayer(msg.slot);
    overlay.hidden = true;
    navigator.vibrate?.([30, 60, 30]);
    send();
  };
  ws.onclose = () => {
    showPlayer(-1);
    if (retry) {
      say(lastError || 'Connexion perdue, nouvelle tentative…');
      // Après le délai du serveur (2 s sans nouvelles) : l'ancienne place est libérée, on la retrouve.
      setTimeout(connect, 2500);
      return;
    }
    // Lien remplacé par l'hôte : on oublie l'ancien et on propose de scanner le nouveau.
    store('invite', '');
    retry = true;
    idle(lastError);
  };
}

// Sans invitation : scanner le QR code de l'hôte. Le détecteur du navigateur suffit (Chrome sur Android) ;
// ailleurs, l'appareil photo du téléphone ouvre le lien tout aussi bien.
const scanButton = document.getElementById('scan');
const camera = document.getElementById('camera');
const canScan = 'BarcodeDetector' in window && navigator.mediaDevices?.getUserMedia;

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
  scanButton.hidden = invited || !canScan;
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
  const detector = new BarcodeDetector({ formats: ['qr_code'] });
  while (!camera.hidden) {
    for (const { rawValue } of await detector.detect(camera).catch(() => [])) {
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
