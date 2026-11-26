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

// Quaternions [w, x, y, z].
const qmul = ([aw, ax, ay, az], [bw, bx, by, bz]) => [
  aw * bw - ax * bx - ay * by - az * bz,
  aw * bx + ax * bw + ay * bz - az * by,
  aw * by - ax * bz + ay * bw + az * bx,
  aw * bz + ax * by - ay * bx + az * bw,
];
const unit = (v) => v.map((c) => c / (Math.hypot(...v) || 1));
const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
// Vecteur v du repère du téléphone, vu du repère fixe.
const rotate = ([w, ...r], v) => {
  const t = cross(r, v).map((c) => 2 * c);
  const rt = cross(r, t);
  return v.map((c, i) => c + w * t[i] + rt[i]);
};

// Visée au gyroscope seul. La pose du téléphone, suivie de sa rotation depuis le premier échantillon, place la
// direction visée (son haut, axe y) dans un repère fixe ; cap et élévation s'en déduisent à chaque fois, rien ne
// s'additionne : revenir au même endroit redonne la même visée, même après des cercles. La verticale de ce repère
// est une moyenne lente de l'accéléromètre (constante de temps `tau`, en s) : les accélérations de la main s'y
// annulent (moins de 0,6° d'écart en grands cercles rapides, bras tendu, à 10 s ; 4° à 2 s), et une erreur n'y
// ferait que pencher les axes, sans dérive. rotationRate donne x, y, z dans l'ordre
// alpha, beta, gamma (Chrome, Firefox, Safari), en °/s. Signes propres au navigateur et zéro du cap ne comptent
// pas : le calibrage ⌖ (aimPosition) en tire l'échelle et le sens.
export function gyroPointer(tau = 10) {
  let q = [1, 0, 0, 0];
  let up = null;
  // Axe du repère fixe qui donne le zéro du cap : le plus horizontal au départ (téléphone tenu debout ou à plat).
  let north;
  return {
    update({ alpha, beta, gamma }, accel, dt) {
      const v = [alpha, beta, gamma].map((c) => (c * RAD * dt) / 2);
      const s = Math.hypot(...v);
      const k = s < 1e-12 ? 1 : Math.sin(s) / s;
      q = unit(qmul(q, [Math.cos(s), ...v.map((c) => c * k)]));
      const g = rotate(q, accel);
      up = up ? up.map((c, i) => c + (g[i] - c) * (dt / (tau + dt))) : g;
      north ??= [[1, 0, 0], [0, 1, 0], [0, 0, 1]].reduce((a, b) => (Math.abs(dot(a, up)) <= Math.abs(dot(b, up)) ? a : b));
    },
    // [cap vers la droite, élévation], en degrés.
    aim(hold) {
      if (!up) return [0, 0];
      const u = unit(up);
      const n = unit(north.map((c, i) => c - dot(north, u) * u[i]));
      const f = rotate(q, [0, hold === 180 ? -1 : 1, 0]);
      return [Math.atan2(dot(f, cross(n, u)), dot(f, n)) / RAD, Math.asin(Math.max(-1, Math.min(1, dot(f, u)))) / RAD];
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
