// Capteurs du téléphone (repère de la spec DeviceMotion) → valeurs du paquet DSU que Dolphin relit en Wiimote.

export const G = 9.80665;
const RAD = Math.PI / 180;

// Repère de l'écran tel qu'on le voit : x à droite, y en haut, z vers soi.
// `angle` : rotation de l'écran par rapport au téléphone (screen.orientation.angle), sens antihoraire.
function toScreen([x, y, z], angle) {
  const c = Math.cos(angle * RAD);
  const s = Math.sin(angle * RAD);
  return [x * c - y * s, x * s + y * c, z];
}

// Repère de la Wiimote : droite, avant (côté capteur IR), haut (côté boutons = écran).
// À l'horizontale, elle se tient croix à gauche, comme pour Mario Kart : l'avant pointe à gauche de l'écran.
function toWiimote([x, y, z], landscape) {
  return landscape ? [y, -x, z] : [x, y, z];
}

// `accel` : accelerationIncludingGravity (m/s²) ; `rate` : rotationRate en [beta, gamma, alpha] (°/s),
// soit autour de x, y, z. Renvoie accel x, y, z (g) puis gyro tangage, lacet, roulis (°/s), dans
// l'ordre du paquet. Signes : ceux de DualShockUDPClient.cpp, où Accel Up = -y, Accel Left = +x,
// Accel Forward = +z, Gyro Pitch Up = +tangage, Yaw Right = +lacet, Roll Right = +roulis.
export function toDSU(accel, rate, angle, landscape) {
  const [aRight, aForward, aUp] = toWiimote(toScreen(accel, angle), landscape);
  const [wRight, wForward, wUp] = toWiimote(toScreen(rate, angle), landscape);
  return [-aRight / G, -aUp / G, aForward / G, wRight, -wUp, wForward];
}

// Angle d'écran pour lequel l'interface est droite. Il suit l'écran quand celui-ci tourne dans le sens de
// la tenue (téléphone retourné), et l'ignore sinon : braquer au volant fait basculer l'écran en portrait.
export function holdAngle(hold, live, sideways) {
  return (live % 180 !== 0) === sideways ? live : hold;
}

// Direction visée par la Wiimote debout (haut du téléphone), d'après alpha et beta de deviceorientation :
// [cap, élévation] en degrés, le cap croissant vers la droite. Le roulis ne déplace pas le pointeur.
export function aimAngles(alpha, beta, hold) {
  const s = hold === 180 ? -1 : 1;
  const a = alpha * RAD;
  const b = beta * RAD;
  const f = [-s * Math.sin(a) * Math.cos(b), s * Math.cos(a) * Math.cos(b), s * Math.sin(b)];
  return [Math.atan2(f[0], f[1]) / RAD, Math.asin(f[2]) / RAD];
}

// Quaternions [w, x, y, z] : orientation du téléphone, de son repère vers celui de la Terre.
const qmul = ([aw, ax, ay, az], [bw, bx, by, bz]) => [
  aw * bw - ax * bx - ay * by - az * bz,
  aw * bx + ax * bw + ay * bz - az * by,
  aw * by - ax * bz + ay * bw + az * bx,
  aw * bz + ax * by - ay * bx + az * bw,
];
const qnorm = (q) => q.map((v) => v / Math.hypot(...q));
const dot = (a, b) => a.reduce((s, v, i) => s + v * b[i], 0);

// D'après deviceorientation : rotations Z-X'-Y'' de alpha, beta, gamma (spec W3C).
export function orientationQuat(alpha, beta, gamma) {
  const half = (deg) => [Math.cos((deg * RAD) / 2), Math.sin((deg * RAD) / 2)];
  const [cz, sz] = half(alpha);
  const [cx, sx] = half(beta);
  const [cy, sy] = half(gamma);
  return qmul(qmul([cz, 0, 0, sz], [cx, sx, 0, 0]), [cy, 0, sy, 0]);
}

// Rotation d'un vecteur [x, y, z] (radians, repère du téléphone), et l'inverse.
function rotationQuat(v) {
  const angle = Math.hypot(...v);
  if (angle < 1e-12) return [1, 0, 0, 0];
  const s = Math.sin(angle / 2) / angle;
  return [Math.cos(angle / 2), ...v.map((c) => c * s)];
}
function rotationVector(q) {
  const [w, ...v] = q[0] < 0 ? q.map((c) => -c) : q;
  const s = Math.hypot(...v);
  return s < 1e-12 ? [0, 0, 0] : v.map((c) => (c / s) * 2 * Math.atan2(s, w));
}

// Comme aimAngles, depuis un quaternion : le haut du téléphone (son axe y) dans le repère de la Terre.
export function aimFromQuat([w, x, y, z], hold) {
  const s = hold === 180 ? -1 : 1;
  const f = [2 * (x * y - w * z), 1 - 2 * (x * x + z * z), 2 * (y * z + w * x)].map((c) => c * s);
  return [Math.atan2(f[0], f[1]) / RAD, Math.asin(Math.max(-1, Math.min(1, f[2]))) / RAD];
}

// Ordre des axes de rotationRate : x, y, z dans l'ordre alpha, beta, gamma pour Chrome, Firefox et Safari (mesuré
// sur un Xiaomi 17T), alors que le texte de la spec mettrait alpha autour de z. Les deux sont essayés, l'orientation
// tranche.
export const gyroXYZ = ({ alpha, beta, gamma }) => [alpha, beta, gamma];
const GYRO_AXES = [gyroXYZ, ({ alpha, beta, gamma }) => [beta, gamma, alpha]];
const WINDOW = 4 * RAD;
const BLOCK = 10;

// Visée fusionnée : chaque devicemotion (60 Hz réguliers) fait tourner l'orientation du gyroscope, chaque
// deviceorientation la recale (constante de temps `tau`, en s). Certains téléphones (Xiaomi 17T) ne donnent
// l'orientation qu'à 30 Hz par à-coups, et Chrome la tait sous 0,1° de changement. Le gyroscope n'est suivi que si,
// sur 10 rotations d'au moins 4°, un ordre d'axes colle à l'orientation (sens et ampleur) nettement mieux que
// l'autre ; c'est revérifié toutes les 10 rotations, un bloc ambigu ne change rien. Sinon l'orientation seule.
export function aimFusion(tau = 0.3) {
  let q = null;
  let tOrientation = 0;
  let tGyro = null;
  let start = null;
  const fresh = () => GYRO_AXES.map(() => [1, 0, 0, 0]);
  let turned = fresh();
  let sums = GYRO_AXES.map(() => ({ cos: 0, gyro: 0, orientation: 0 }));
  // axes : undefined tant que rien n'est tranché, null si aucun ordre ne colle, sinon l'indice dans GYRO_AXES.
  const check = { windows: 0, axes: undefined, results: [] };
  const trusted = () => Number.isInteger(check.axes);
  return {
    check,
    get quat() {
      return q;
    },
    orientation(alpha, beta, gamma, t) {
      const m = orientationQuat(alpha, beta, gamma);
      if (!start) {
        start = m;
      } else if (Math.hypot(...rotationVector(turned[0])) > WINDOW) {
        const d = rotationVector(qmul([start[0], -start[1], -start[2], -start[3]], m));
        turned.forEach((w, i) => {
          const g = rotationVector(w);
          sums[i].cos += dot(d, g) / (Math.hypot(...d) * Math.hypot(...g) || 1);
          sums[i].gyro += Math.hypot(...g);
          sums[i].orientation += Math.hypot(...d);
        });
        start = m;
        turned = fresh();
        // Moyennes du bloc en cours, affichées par la page de test ; verdict au bout du bloc.
        const n = (check.windows++ % BLOCK) + 1;
        check.results = sums.map(({ cos, gyro, orientation }) => ({ cos: cos / n, ratio: gyro / orientation }));
        if (n === BLOCK) {
          const [best, other] = check.results.map((_, i) => i).sort((a, b) => check.results[b].cos - check.results[a].cos);
          const { cos, ratio } = check.results[best];
          if (cos < 0.9 || Math.abs(ratio - 1) > 0.3) check.axes = null;
          else if (cos - check.results[other].cos > 0.15) check.axes = best;
          sums = GYRO_AXES.map(() => ({ cos: 0, gyro: 0, orientation: 0 }));
        }
      }
      if (trusted() && q) {
        const k = 1 - Math.exp(-(t - tOrientation) / 1000 / tau);
        const target = dot(q, m) < 0 ? m.map((c) => -c) : m;
        q = qnorm(q.map((c, i) => c + (target[i] - c) * k));
      } else {
        q = m;
      }
      tOrientation = t;
    },
    // rotationRate tel quel (°/s).
    gyro(rate, t) {
      const dt = tGyro === null ? 0 : Math.min(Math.max((t - tGyro) / 1000, 0), 0.05);
      tGyro = t;
      const steps = GYRO_AXES.map((axes) => rotationQuat(axes(rate).map((r) => r * RAD * dt)));
      turned = turned.map((w, i) => qmul(w, steps[i]));
      if (trusted() && q) q = qnorm(qmul(q, steps[check.axes]));
    },
  };
}

const wrap = (d) => ((((d + 180) % 360) + 360) % 360) - 180;

// Coins visés au calibrage trop proches : on garderait un pointeur affolé.
export function validCorners(topLeft, bottomRight) {
  return Math.abs(wrap(bottomRight[0] - topLeft[0])) > 2 && Math.abs(topLeft[1] - bottomRight[1]) > 1;
}

// Pointeur de -1 à 1 (y vers le haut) entre les coins haut gauche et bas droit visés au calibrage.
export function aimPosition([h, e], topLeft, bottomRight) {
  const halfYaw = wrap(bottomRight[0] - topLeft[0]) / 2;
  const halfPitch = (topLeft[1] - bottomRight[1]) / 2;
  const clamp = (v) => Math.max(-1, Math.min(1, v));
  return [
    clamp(wrap(h - topLeft[0] - halfYaw) / halfYaw),
    clamp((e - (topLeft[1] + bottomRight[1]) / 2) / halfPitch),
  ];
}

// Volant au joystick (Mario Kart) : ce que mesurerait le téléphone tenu en volant, écran face à soi, tourné de
// `s` (−1 à 1 à sensibilité ×1, vers la droite) fois cet angle. Valeurs DSU, comme `toDSU` ; gyroscope à zéro.
const WHEEL_MAX = 50;
// Au-delà, le volant passerait à l'envers.
const WHEEL_LIMIT = 85;
const clampAngle = (deg) => Math.max(-WHEEL_LIMIT, Math.min(WHEEL_LIMIT, deg)) * RAD;
export function wheelMotion(s) {
  const t = clampAngle(s * WHEEL_MAX);
  return [-Math.cos(t), 0, Math.sin(t), 0, 0, 0];
}

// Joystick en volant : la flèche (objet de Mario Kart) ne part que sur un coup de pouce franc, de la zone calme
// (moins de 35 % de la course) au-delà de 75 % en moins de 180 ms ; elle reste tenue tant que le pouce n'est pas
// revenu au calme (banane derrière soi). Un pouce qui dérive en braquant ne lance rien.
// `state` : { calm : dernier instant au calme (ms), item }, `ly` : écart vertical (y vers le bas), `reach` : course.
const FLICK_CALM = 0.35;
const FLICK_FAR = 0.75;
const FLICK_MS = 180;
export function wheelItem(state, ly, reach, now) {
  const v = Math.abs(ly) / reach;
  if (v < FLICK_CALM) return { calm: now, item: null };
  if (state.item) return state;
  if (v > FLICK_FAR && now - state.calm <= FLICK_MS) return { calm: state.calm, item: ly < 0 ? 'up' : 'down' };
  return state;
}

// Sensibilité de l'inclinaison (tenue en volant) : l'angle du volant, mesuré dans le plan de l'écran, multiplié
// par `k`. La part hors de ce plan (téléphone penché vers soi) et le gyroscope sont gardés.
export function tiltGain(motion, k) {
  const [x, y, z] = motion;
  const r = Math.hypot(x, z);
  if (k === 1 || r === 0) return motion;
  const t = clampAngle((Math.atan2(z, -x) / RAD) * k);
  return [-r * Math.cos(t), y, r * Math.sin(t), ...motion.slice(3)];
}

// Filtre « 1 € » (Casiez, Roussel, Vogel, 2012), celui des pointeurs : il lisse fort quand la valeur bouge peu
// (tremblement de la main, bruit du capteur) et presque plus quand elle bouge vite (pas de traîne). Réglé pour un
// pointeur de −1 à 1 : coupure à 2 Hz au repos, +2,5 Hz par unité/s de vitesse. `t` en ms.
export function oneEuro({ minCutoff = 2, beta = 2.5, dCutoff = 1 } = {}) {
  const alpha = (cutoff, dt) => 1 / (1 + 1 / (2 * Math.PI * cutoff * dt));
  let x;
  let dx = 0;
  let last;
  return (value, t) => {
    if (x === undefined) {
      x = value;
      last = t;
      return x;
    }
    const dt = (t - last) / 1000;
    if (dt <= 0) return x;
    last = t;
    dx += alpha(dCutoff, dt) * ((value - x) / dt - dx);
    x += alpha(minCutoff + beta * Math.abs(dx), dt) * (value - x);
    return x;
  };
}

const DIRECTIONS = ['right', 'down', 'left', 'up'];

// Croix tactile : la direction (telle que dessinée) la plus proche d'un doigt à (dx, dy) du centre, en pixels
// d'écran, y vers le bas. `radius` : demi-largeur de la croix ; `rotation` : rotation CSS de l'interface (°,
// horaire). Une seule à la fois, pas de diagonale par mégarde ; rien au centre ni au-delà de 1,2 rayon.
export function dpadDirection(dx, dy, radius, rotation) {
  const distance = Math.hypot(dx, dy);
  if (distance < radius * 0.16 || distance > radius * 1.2) return null;
  const [x, y] = toLocal(dx, dy, rotation);
  return DIRECTIONS[(Math.round(Math.atan2(y, x) / (Math.PI / 2)) + 4) % 4];
}

// Écart à l'écran (pixels, y vers le bas) → repère de l'interface tournée de `rotation` (°, horaire).
export function toLocal(dx, dy, rotation) {
  const a = rotation * RAD;
  return [dx * Math.cos(a) + dy * Math.sin(a), -dx * Math.sin(a) + dy * Math.cos(a)];
}

// Joystick : directions pour un pouce à (x, y) du centre, dans le repère de l'interface. Huit directions, mais
// chaque diagonale n'occupe que 30° (contre 60° par direction droite) : on ne la prend pas par mégarde.
export function stickDirections(x, y, radius) {
  if (Math.hypot(x, y) < radius * 0.25) return [];
  const a = Math.atan2(y, x) / RAD;
  const sector = Math.round(a / 45);
  if (sector % 2 === 0 || Math.abs(a - sector * 45) > 15) return [DIRECTIONS[(Math.round(a / 90) + 4) % 4]];
  return [DIRECTIONS[(Math.floor(a / 90) + 4) % 4], DIRECTIONS[(Math.ceil(a / 90) + 4) % 4]];
}

// Verticale (unitaire, vers le haut) dans le repère du téléphone, d'après beta et gamma de deviceorientation.
export function upFromOrientation(beta, gamma) {
  const b = beta * RAD;
  const g = gamma * RAD;
  return [-Math.sin(g) * Math.cos(b), Math.sin(b), Math.cos(b) * Math.cos(g)];
}
