// node --test motion.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { G, aimAngles, aimFromQuat, aimFusion, aimPosition, orientationQuat, dpadDirection, holdAngle, oneEuro, stickDirections, tiltGain, wheelItem, wheelMotion, toDSU, upFromOrientation, validCorners } from './web/motion.mjs';

const near = (got, want) =>
  want.forEach((w, i) => assert.ok(Math.abs(got[i] - w) < 1e-9, `${got} ≠ ${want}`));

// Lecture de Dolphin (DualShockUDPClient.cpp), ramenée en g et °/s.
const dolphin = ([x, y, z, pitch, yaw, roll]) => ({
  up: -y, left: x, forward: z, pitchUp: pitch, yawRight: yaw, rollRight: roll,
});

const still = [0, 0, 0];

test('à plat, écran vers le haut : +1 g vers le haut de la Wiimote, quelle que soit la tenue', () => {
  for (const [angle, landscape] of [[0, false], [90, true], [270, true], [180, false]]) {
    const d = dolphin(toDSU([0, 0, G], still, angle, landscape));
    near([d.up, d.left, d.forward], [1, 0, 0]);
  }
});

test('portrait debout : l’avant (capteur IR) pointe au plafond', () => {
  const d = dolphin(toDSU([0, G, 0], still, 0, false));
  near([d.up, d.left, d.forward], [0, 0, 1]);
});

test('volant droit (paysage, écran face à soi) : la gravité tire sur la droite de la Wiimote', () => {
  // Haut du téléphone à gauche (angle 90) : son bord droit est en haut.
  near(Object.values(dolphin(toDSU([G, 0, 0], still, 90, true))).slice(0, 3), [0, -1, 0]);
  // Haut du téléphone à droite (angle 270) : son bord gauche est en haut.
  near(Object.values(dolphin(toDSU([-G, 0, 0], still, 270, true))).slice(0, 3), [0, -1, 0]);
});

test('tourner le volant à droite lève l’avant, comme une Wiimote de côté', () => {
  // Angle 90, volant tourné de 30° dans le sens horaire.
  const t = 30 * Math.PI / 180;
  const d = dolphin(toDSU([G * Math.cos(t), G * Math.sin(t), 0], still, 90, true));
  near([d.left, d.forward], [-Math.cos(t), Math.sin(t)]);
});

test('gyroscope : lacet, tangage et roulis dans le sens de Dolphin', () => {
  // Portrait à plat, rotation antihoraire vue d’au-dessus : la Wiimote tourne à gauche.
  assert.equal(dolphin(toDSU([0, 0, G], [0, 0, 90], 0, false)).yawRight, -90);
  // Le haut du téléphone se lève : tangage vers le haut.
  assert.equal(dolphin(toDSU([0, 0, G], [90, 0, 0], 0, false)).pitchUp, 90);
  // Paysage (angle 90) : l’avant est le haut du téléphone ; le côté droit qui descend = roulis à droite.
  near([dolphin(toDSU([0, 0, G], [0, 90, 0], 90, true)).rollRight], [90]);
});

test('la tenue ignore l’écran qui bascule quand on braque, mais suit un retournement', () => {
  assert.equal(holdAngle(90, 0, true), 90); // horizontale, l'écran passe en portrait : on garde
  assert.equal(holdAngle(90, 270, true), 270); // téléphone retourné : on suit
  assert.equal(holdAngle(0, 90, false), 0); // verticale, l'écran passe en paysage : on garde
  assert.equal(holdAngle(0, 180, false), 180);
});

test('visée : tourner à gauche baisse le cap, lever le bout monte, le roulis ne compte pas', () => {
  near(aimAngles(0, 0, 0), [0, 0]);
  near(aimAngles(30, 0, 0), [-30, 0]); // alpha croît en tournant à gauche (antihoraire vu d'au-dessus)
  near(aimAngles(0, 10, 0), [0, 10]);
});

test('pointeur calé sur les coins visés, y compris à cheval sur ±180°', () => {
  const tl = [-20, 10];
  const br = [20, -10];
  near(aimPosition([0, 0], tl, br), [0, 0]);
  near(aimPosition([20, -10], tl, br), [1, -1]);
  near(aimPosition([-10, 5], tl, br), [-0.5, 0.5]);
  near(aimPosition([90, 40], tl, br), [1, 1]); // hors de l'écran : bloqué au bord
  near(aimPosition([-175, 0], [170, 5], [-170, -5]), [0.5, 0]);
  assert.ok(!validCorners([3, 2], [3.5, 1.8]));
  assert.ok(validCorners(tl, br));
});

test('croix tactile : direction la plus proche, centre mort, portée et interface tournée', () => {
  assert.equal(dpadDirection(50, 0, 100, 0), 'right');
  assert.equal(dpadDirection(0, -50, 100, 0), 'up');
  // En diagonale : une seule direction, la plus proche.
  assert.equal(dpadDirection(45, 40, 100, 0), 'right');
  assert.equal(dpadDirection(40, 45, 100, 0), 'down');
  assert.equal(dpadDirection(-40, -45, 100, 0), 'up');
  assert.equal(dpadDirection(5, 0, 100, 0), null); // pouce posé au centre
  assert.equal(dpadDirection(115, 0, 100, 0), 'right'); // un peu hors du dessin : toléré
  assert.equal(dpadDirection(130, 0, 100, 0), null); // trop loin
  // Interface tournée de 90° (horaire) : un doigt en bas de l'écran est à droite de la croix dessinée.
  assert.equal(dpadDirection(0, 50, 100, 90), 'right');
});

test('volant au joystick : la mesure du téléphone tourné en volant', () => {
  near(wheelMotion(0), toDSU([G, 0, 0], still, 90, true)); // droit
  const t = 50 * Math.PI / 180; // à fond à droite : tourné de 50° dans le sens horaire
  near(wheelMotion(1), toDSU([G * Math.cos(t), G * Math.sin(t), 0], still, 90, true));
  near(wheelMotion(-0.5), toDSU([G * Math.cos(-t / 2), G * Math.sin(-t / 2), 0], still, 90, true));
});

test('sensibilité : l’angle du volant multiplié, sans dépasser 85°', () => {
  const wheel = (deg) => toDSU([G * Math.cos(deg * Math.PI / 180), G * Math.sin(deg * Math.PI / 180), 0], still, 90, true);
  near(tiltGain(wheel(30), 1), wheel(30));
  near(tiltGain(wheel(30), 1.5), wheel(45));
  near(tiltGain(wheel(-20), 0.5), wheel(-10));
  near(tiltGain(wheel(60), 2), wheel(85)); // plafonné
  // Le téléphone penché (part hors du plan de l'écran) et le gyroscope ne bougent pas.
  near(tiltGain([-0.6, -0.8, 0, 1, 2, 3], 2).slice(1), [-0.8, 0, 1, 2, 3]);
  near(wheelMotion(2), wheel(85)); // joystick à sensibilité ×2, à fond
});

test('volant : objet seulement sur un coup de pouce franc, tenu jusqu’au retour au calme', () => {
  const run = (steps) => steps.reduce((s, [ly, t]) => wheelItem(s, ly, 100, t), { calm: 0, item: null }).item;
  assert.equal(run([[0, 0], [-90, 80]]), 'up'); // coup franc vers le haut
  assert.equal(run([[0, 0], [60, 60], [95, 120]]), 'down');
  assert.equal(run([[0, 0], [-50, 150], [-90, 400]]), null); // montée lente
  assert.equal(run([[0, 0], [-50, 50], [-60, 300], [-90, 320]]), null); // pouce resté à mi-course puis poussé
  assert.equal(run([[0, 0], [-90, 80], [-50, 600]]), 'up'); // tenu tant qu'il n'est pas revenu au calme
  assert.equal(run([[0, 0], [-90, 80], [-20, 600]]), null); // relâché
});

test('filtre du pointeur : tremblement gommé au repos, peu de retard en mouvement', () => {
  // Main tenue sur un point (0,3), tremblement à 9 Hz de ±0,03 et bruit du capteur, échantillons à 60 Hz.
  const still = oneEuro();
  let spread = 0;
  for (let i = 0; i < 240; i++) {
    const t = i * 1000 / 60;
    const raw = 0.3 + 0.03 * Math.sin(2 * Math.PI * 9 * t / 1000) + 0.01 * Math.sin(i * 2.7);
    const out = still(raw, t);
    if (i > 60) spread = Math.max(spread, Math.abs(out - 0.3));
  }
  assert.ok(spread < 0.012, `tremblement restant ±${spread.toFixed(4)} (±0,04 en entrée)`);
  // Balayage d'un bord à l'autre en 0,5 s : le pointeur suit à moins d'un dixième d'écran.
  const sweep = oneEuro();
  let lag = 0;
  for (let i = 0; i <= 30; i++) {
    const t = i * 1000 / 60;
    const raw = -1 + 2 * Math.min(1, t / 500);
    lag = Math.max(lag, Math.abs(sweep(raw, t) - raw));
  }
  assert.ok(lag < 0.2, `retard ${lag.toFixed(3)} sur une course de 2`);
});

test('joystick : huit directions, diagonales étroites, centre mort', () => {
  assert.deepEqual(stickDirections(50, 0, 100), ['right']);
  assert.deepEqual(stickDirections(0, -50, 100), ['up']);
  assert.deepEqual(stickDirections(40, 40, 100), ['right', 'down']); // 45° pile
  assert.deepEqual(stickDirections(-40, -40, 100), ['left', 'up']);
  assert.deepEqual(stickDirections(40, -40, 100), ['up', 'right']);
  assert.deepEqual(stickDirections(-40, 40, 100), ['down', 'left']);
  // 25° sous l'horizontale : hors de la bande diagonale (45 ± 15°), droite seule.
  const t = 25 * Math.PI / 180;
  assert.deepEqual(stickDirections(60 * Math.cos(t), 60 * Math.sin(t), 100), ['right']);
  assert.deepEqual(stickDirections(10, 5, 100), []); // pouce au centre
  assert.deepEqual(stickDirections(300, 0, 100), ['right']); // le pouce peut sortir du dessin
});

test('verticale tirée de l’orientation, dans le repère de la spec', () => {
  near(upFromOrientation(0, 0), [0, 0, 1]);
  near(upFromOrientation(90, 0), [0, 1, 0]);
  near(upFromOrientation(0, -90), [1, 0, 0]);
});

// Même visée, au tour près (−180° et 180° se valent).
const sameAim = ([h1, e1], [h2, e2]) => near([((h1 - h2 + 540) % 360) - 180, e1 - e2], [0, 0]);

test('visée depuis un quaternion : la même que depuis les angles, roulis et tenue compris', () => {
  for (const [a, b, g] of [[0, 0, 0], [30, 10, 0], [200, -40, 25], [350, 80, -60]]) {
    for (const hold of [0, 180]) sameAim(aimFromQuat(orientationQuat(a, b, g), hold), aimAngles(a, b, hold));
  }
});

// Lacet autour de la verticale, bout levé de 10° : alpha(t) = 40 sin t. Vu du téléphone, la rotation est
// alpha' × (0, sin 10°, cos 10°) ; `axes` permet de fausser ce que donne le gyroscope.
function sweep(fusion, { seconds = 8, orientationEvery = 6, axes = (r) => r } = {}) {
  const beta = 10;
  let worst = 0;
  for (let i = 0; i <= seconds * 60; i++) {
    const t = i / 60;
    const rate = 40 * Math.cos(t);
    fusion.gyro(axes([0, rate * Math.sin(beta * Math.PI / 180), rate * Math.cos(beta * Math.PI / 180)]), t * 1000);
    if (i % orientationEvery === 0) fusion.orientation((40 * Math.sin(t) + 360) % 360, beta, 0, t * 1000);
    if (t > seconds - 3) {
      const [h, e] = aimFromQuat(fusion.quat, 0);
      const [wh, we] = aimAngles(40 * Math.sin(t), beta, 0);
      worst = Math.max(worst, Math.abs(h - wh), Math.abs(e - we));
    }
  }
  return worst;
}

test('visée fusionnée : le gyroscope comble une orientation à 10 Hz, à 0,2° près', () => {
  const fusion = aimFusion();
  const worst = sweep(fusion);
  assert.equal(fusion.check.trusted, true);
  assert.ok(worst < 0.2, `écart ${worst}°`);
  // Sans le gyroscope, la visée resterait sur l'orientation de 100 ms plus tôt : jusqu'à 4° de retard.
  assert.ok(sweep(aimFusion(), { axes: () => [0, 0, 0] }) > 3);
});

test('visée fusionnée : gyroscope ignoré si ses axes ou son unité ne collent pas à l’orientation', () => {
  const swapped = aimFusion();
  sweep(swapped, { axes: ([x, y, z]) => [x, z, y] });
  assert.equal(swapped.check.trusted, false);
  const radians = aimFusion();
  sweep(radians, { axes: (r) => r.map((c) => c * Math.PI / 180) });
  assert.equal(radians.check.trusted, false);
  // Tant qu'il n'est pas confirmé : l'orientation telle quelle.
  const fresh = aimFusion();
  fresh.orientation(30, 10, 5, 0);
  fresh.gyro([50, 50, 50], 16);
  sameAim(aimFromQuat(fresh.quat, 0), aimAngles(30, 10, 0));
});
