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
// direction visée (son haut, axe y) dans un repère fixe : revenir au même endroit redonne la même direction, même
// après des cercles. rotationRate donne x, y, z dans l'ordre alpha, beta, gamma (Chrome, Firefox, Safari), en °/s.
export function gyroPointer() {
  let q = [1, 0, 0, 0];
  // Les deux derniers échantillons : [instant (ms), rotation (°/s)].
  let last = null;
  let previous = null;
  return {
    // rotationRate d'un devicemotion et son instant (ms). Les instants d'arrivée, même décalés de 1 à 3 ms, valent
    // mieux qu'une horloge reconstituée (simulation).
    update({ alpha, beta, gamma }, t) {
      const rate = [alpha, beta, gamma];
      // Un échantillon vide ou invalide empoisonnerait la pose pour de bon : ignoré.
      if (![...rate, t].every(Number.isFinite)) return;
      // Durée entre deux échantillons ; au-delà de 100 ms (page en arrière-plan), la rotation d'alors ne dit plus
      // rien du trou.
      const span = (a, b) => (a && b[0] - a[0] > 0 && b[0] - a[0] <= 100 ? (b[0] - a[0]) / 1000 : 0);
      const dt = span(last, [t]);
      // Rotation (radians, repère du téléphone) entre les deux derniers échantillons : la vitesse suit la parabole
      // des trois derniers (trapèzes corrigés de sa courbure, sans attendre le suivant), plus la correction de
      // conicité. Sans elles, dix cercles rapides tourneraient la pose de 1° à 60 Hz ; avec, de 0,02°.
      let turn = [0, 0, 0];
      if (dt > 0) {
        const [r1, h1] = [last[1], span(previous, last)];
        const curve = (i) => (h1 ? ((rate[i] - r1[i]) * h1 + (previous[1][i] - r1[i]) * dt) / (h1 * dt * (h1 + dt)) : 0);
        const coning = cross(r1, rate);
        turn = rate.map((c, i) => (((c + r1[i]) / 2) * dt - (curve(i) * dt ** 3) / 6) * RAD + (coning[i] * (RAD * dt) ** 2) / 12);
      }
      previous = last;
      last = [t, rate];
      const s = Math.hypot(...turn) / 2;
      const k = s < 1e-12 ? 0.5 : Math.sin(s) / (2 * s);
      q = unit(qmul(q, [Math.cos(s), ...turn.map((c) => c * k)]));
    },
    // Direction visée (vecteur unitaire du repère fixe), le bas du téléphone si on le tient retourné ; null avant le
    // premier échantillon.
    direction(hold) {
      return last ? rotate(q, [0, hold === 180 ? -1 : 1, 0]) : null;
    },
  };
}

// Écran d'après les directions visées à ses quatre coins au calibrage (haut gauche, haut droit, bas droit, bas
// gauche) : projetées sur un plan face à elles, la perspective (homographie) qui envoie ces quatre points sur les
// coins de l'écran place exactement tout le reste, qu'on soit de face ou de biais, tant que la main reste où elle
// était. Ni la gravité (l'accéléromètre, décalé de quelques centièmes de g, pencherait les axes) ni le format de
// l'écran n'y entrent ; les signes propres au navigateur non plus. Rend la position de -1 à 1 (y vers le haut)
// d'une direction, bloquée aux bords ; null si les coins ne dessinent pas un quadrilatère convexe d'au moins 1° de
// côté (appui en double, ordre faux).
export function screenFrom(corners) {
  const normal = unit(corners.reduce((sum, v) => sum.map((c, i) => c + v[i]), [0, 0, 0]));
  const axis = [[1, 0, 0], [0, 1, 0], [0, 0, 1]].reduce((a, b) => (Math.abs(dot(a, normal)) <= Math.abs(dot(b, normal)) ? a : b));
  const [e1, e2] = [unit(cross(normal, axis)), unit(cross(normal, unit(cross(normal, axis))))];
  // Derrière soi, la profondeur bornée garde des coordonnées finies.
  const plane = (v) => [dot(v, e1), dot(v, e2)].map((c) => c / Math.max(dot(v, normal), 1e-3));
  const p = corners.map(plane);
  const sides = p.map((a, i) => [p[(i + 1) % 4][0] - a[0], p[(i + 1) % 4][1] - a[1]]);
  const turns = sides.map((a, i) => a[0] * sides[(i + 1) % 4][1] - a[1] * sides[(i + 1) % 4][0]);
  const convex = turns.every((t) => t > 0) || turns.every((t) => t < 0);
  if (!convex || sides.some((a) => Math.hypot(...a) < Math.tan(RAD))) return null;
  // Homographie du carré unité (coins (0,0), (1,0), (1,1), (0,1)) vers le quadrilatère (Heckbert), puis son inverse
  // (la comatrice suffit : coordonnées homogènes).
  const [[x0, y0], [x1, y1], [x2, y2], [x3, y3]] = p;
  const [sx, sy] = [x0 - x1 + x2 - x3, y0 - y1 + y2 - y3];
  const [dx1, dx2, dy1, dy2] = [x1 - x2, x3 - x2, y1 - y2, y3 - y2];
  const det = dx1 * dy2 - dx2 * dy1;
  const [g, h] = [(sx * dy2 - dx2 * sy) / det, (dx1 * sy - sx * dy1) / det];
  const [a, b, c, d, e, f] = [x1 - x0 + g * x1, x3 - x0 + h * x3, x0, y1 - y0 + g * y1, y3 - y0 + h * y3, y0];
  const inverse = [
    [e - f * h, c * h - b, b * f - c * e],
    [f * g - d, a - c * g, c * d - a * f],
    [d * h - e * g, b * g - a * h, a * e - b * d],
  ];
  // Coordonnées homogènes de signe quelconque : positives au centre de l'écran.
  if (inverse[2][2] < 0) inverse.forEach((r) => r.forEach((c, j) => (r[j] = -c)));
  const clamp = (v) => Math.max(-1, Math.min(1, v));
  let held = [0, 0];
  const toScreen = (direction) => {
    const [x, y] = plane(direction);
    const [u, v, w] = inverse.map((r) => r[0] * x + r[1] * y + r[2]);
    // Au-delà de l'horizon de la perspective (visée très loin de l'écran), le pointeur reste où il était.
    if (w <= 1e-9 * Math.hypot(u, v, w)) return held;
    held = [clamp((2 * u) / w - 1), clamp(1 - (2 * v) / w)];
    return held;
  };
  // Direction du centre de l'écran (milieu du carré unité), pour recentrer.
  const [cx, cy, cw] = [[a, b, c], [d, e, f], [g, h, 1]].map((r) => (r[0] + r[1]) / 2 + r[2]);
  toScreen.center = unit(normal.map((n, i) => n + (cx / cw) * e1[i] + (cy / cw) * e2[i]));
  return toScreen;
}

// Recentrage : la rotation la plus courte (Rodrigues) qui ramène la visée `from` (le milieu de l'écran, visé après
// une dérive du gyroscope) sur `to` (le centre calibré), à appliquer à toute direction. Centre exact ; aux coins,
// 4 à 7 px (sur 1 920) par degré de dérive, que ni une correction du cap puis de la hauteur ni rien d'autre à un
// seul point visé ne ferait mieux (simulation) ; le roulis dérivé, lui, demande un nouveau calibrage.
export function turnTo(from, to) {
  const k = cross(from, to);
  const [s2, c] = [dot(k, k), dot(from, to)];
  if (s2 < 1e-24) return (v) => v;
  return (v) => {
    const kv = cross(k, v);
    const f = (dot(k, v) * (1 - c)) / s2;
    return v.map((x, i) => x * c + kv[i] + k[i] * f);
  };
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
// `reach` : portée, en rayons ; Infinity pour un doigt posé sur la croix, qu'il garde même en en sortant.
export function dpadDirection(dx, dy, radius, rotation, reach = 1.2) {
  const distance = Math.hypot(dx, dy);
  if (distance < radius * 0.16 || distance > radius * reach) return null;
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
