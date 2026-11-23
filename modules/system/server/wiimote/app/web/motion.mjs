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

// Verticale (unitaire, vers le haut) dans le repère du téléphone, d'après beta et gamma de deviceorientation.
export function upFromOrientation(beta, gamma) {
  const b = beta * RAD;
  const g = gamma * RAD;
  return [-Math.sin(g) * Math.cos(b), Math.sin(b), Math.cos(b) * Math.cos(g)];
}
