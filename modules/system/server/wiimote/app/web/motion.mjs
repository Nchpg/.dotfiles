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

const DIRECTIONS = ['right', 'down', 'left', 'up'];

// Croix tactile : la direction (telle que dessinée) la plus proche d'un doigt à (dx, dy) du centre, en pixels
// d'écran, y vers le bas. `radius` : demi-largeur de la croix ; `rotation` : rotation CSS de l'interface (°,
// horaire). Une seule à la fois, pas de diagonale par mégarde ; rien au centre ni au-delà de 1,2 rayon.
export function dpadDirection(dx, dy, radius, rotation) {
  const distance = Math.hypot(dx, dy);
  if (distance < radius * 0.16 || distance > radius * 1.2) return null;
  const a = rotation * RAD;
  const x = dx * Math.cos(a) + dy * Math.sin(a);
  const y = -dx * Math.sin(a) + dy * Math.cos(a);
  return DIRECTIONS[(Math.round(Math.atan2(y, x) / (Math.PI / 2)) + 4) % 4];
}

// Verticale (unitaire, vers le haut) dans le repère du téléphone, d'après beta et gamma de deviceorientation.
export function upFromOrientation(beta, gamma) {
  const b = beta * RAD;
  const g = gamma * RAD;
  return [-Math.sin(g) * Math.cos(b), Math.sin(b), Math.cos(b) * Math.cos(g)];
}
