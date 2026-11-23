import { G, toDSU, upFromOrientation } from './motion.mjs';

// Bit de chaque bouton dans le message : même ordre que `buttons` dans dsu.go.
const BIT = { A: 0, B: 1, 1: 2, 2: 3, '-': 4, '+': 5, Home: 6, Up: 7, Down: 8, Left: 9, Right: 10, Recenter: 11 };

// Flèche vue à l'écran → bouton de la Wiimote. De côté, son haut (côté capteur) est à gauche.
const DPAD = {
  portrait: { up: 'Up', down: 'Down', left: 'Left', right: 'Right' },
  landscape: { left: 'Up', right: 'Down', up: 'Right', down: 'Left' },
};

const overlay = document.getElementById('overlay');
const status = document.getElementById('status');
const startButton = document.getElementById('start');
const leds = [...document.querySelectorAll('.leds i')];
const landscapeQuery = matchMedia('(orientation: landscape)');

const pointers = new Map();
const packet = new DataView(new ArrayBuffer(26));
let buttons = 0;
let motion = [0, -1, 0, 0, 0, 0];
let ws;
let lastError = '';
let wakeLock;

// Selon le navigateur, accelerationIncludingGravity n'a pas toujours le signe de la spec : on le recoupe
// avec la verticale que donne deviceorientation, sur les premiers échantillons au repos.
let accelSign = 1;
let orientation;
let agreement = 0;
let samples = 0;

const angle = () => (((screen.orientation?.angle ?? window.orientation ?? 0) % 360) + 360) % 360;

function say(text) {
  status.textContent = text;
  overlay.hidden = false;
}

function store(key, value) {
  try {
    if (value === undefined) return localStorage.getItem(key);
    localStorage.setItem(key, value);
  } catch {
    return null;
  }
}

function send() {
  if (ws?.readyState !== WebSocket.OPEN || ws.bufferedAmount > 1024) return;
  packet.setUint16(0, buttons, true);
  motion.forEach((v, i) => packet.setFloat32(2 + 4 * i, v, true));
  ws.send(packet.buffer);
}

// Recalculé à chaque contact : glisser d'un bouton à l'autre et appuyer à plusieurs doigts marchent.
function refreshButtons() {
  const mode = landscapeQuery.matches ? 'landscape' : 'portrait';
  const pressed = new Set();
  let next = 0;
  for (const { x, y } of pointers.values()) {
    const el = document.elementFromPoint(x, y)?.closest('[data-btn], [data-dir]');
    if (!el) continue;
    pressed.add(el);
    next |= 1 << BIT[el.dataset.btn ?? DPAD[mode][el.dataset.dir]];
  }
  for (const el of document.querySelectorAll('[data-btn], [data-dir]')) {
    el.classList.toggle('on', pressed.has(el));
  }
  if (next === buttons) return;
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
  refreshButtons();
};
addEventListener('pointerdown', track);
addEventListener('pointermove', (e) => pointers.has(e.pointerId) && track(e));
addEventListener('pointerup', untrack);
addEventListener('pointercancel', untrack);
addEventListener('contextmenu', (e) => e.preventDefault());

addEventListener('deviceorientation', (e) => {
  if (e.beta !== null) orientation = e;
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

  motion = toDSU(
    [a.x * accelSign, a.y * accelSign, a.z * accelSign],
    [r?.beta ?? 0, r?.gamma ?? 0, r?.alpha ?? 0],
    angle(),
    landscapeQuery.matches,
  );
  send();
});

// Le serveur libère une manette muette depuis 2 s.
setInterval(send, 200);

function showPlayer(slot) {
  leds.forEach((led, i) => led.classList.toggle('on', i === slot));
}

function connect() {
  const scheme = location.protocol === 'https:' ? 'wss' : 'ws';
  ws = new WebSocket(`${scheme}://${location.host}/ws?slot=${store('slot') ?? ''}`);
  ws.onmessage = (e) => {
    const msg = JSON.parse(e.data);
    if (msg.error) {
      lastError = msg.error;
      return;
    }
    lastError = '';
    store('slot', String(msg.slot));
    showPlayer(msg.slot);
    overlay.hidden = true;
    navigator.vibrate?.([30, 60, 30]);
    send();
  };
  ws.onclose = () => {
    showPlayer(-1);
    say(lastError || 'Connexion perdue, nouvelle tentative…');
    setTimeout(connect, 1000);
  };
}

async function keepAwake() {
  if (document.visibilityState !== 'visible' || !navigator.wakeLock) return;
  wakeLock = await navigator.wakeLock.request('screen').catch(() => undefined);
}
document.addEventListener('visibilitychange', keepAwake);

startButton.addEventListener('click', async () => {
  startButton.hidden = true;
  say('Connexion…');
  // Tout dans le geste de l'utilisateur : iOS n'accorde les capteurs et Android le plein écran qu'ainsi.
  if (!matchMedia('(display-mode: fullscreen), (display-mode: standalone)').matches) {
    document.documentElement.requestFullscreen?.().catch(() => {});
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
