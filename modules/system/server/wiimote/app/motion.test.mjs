// node --test motion.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { G, aimPosition, gyroPointer, dpadDirection, holdAngle, oneEuro, stickDirections, tiltGain, wheelItem, wheelMotion, toDSU, upFromOrientation, validCorners } from './web/motion.mjs';

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

// Pose du téléphone (de son repère vers la pièce, z en haut) : cap ψ (vers la gauche, comme alpha), élévation θ du
// haut du téléphone, roulis φ autour de lui.
const matMul = (A, B) => A.map((r) => [0, 1, 2].map((j) => r[0] * B[0][j] + r[1] * B[1][j] + r[2] * B[2][j]));
const transpose = (A) => [0, 1, 2].map((i) => A.map((r) => r[i]));
const apply = (A, v) => A.map((r) => r[0] * v[0] + r[1] * v[1] + r[2] * v[2]);
const pose = (psi, theta, phi) => {
  const [a, b, c] = [psi, theta, phi].map((d) => d * Math.PI / 180);
  const Rz = [[Math.cos(a), -Math.sin(a), 0], [Math.sin(a), Math.cos(a), 0], [0, 0, 1]];
  const Rx = [[1, 0, 0], [0, Math.cos(b), -Math.sin(b)], [0, Math.sin(b), Math.cos(b)]];
  const Ry = [[Math.cos(c), 0, Math.sin(c)], [0, 1, 0], [-Math.sin(c), 0, Math.cos(c)]];
  return matMul(matMul(Rz, Rx), Ry);
};

// Joue une trajectoire (pose à l'instant t, en s) de `from` à `to` : ce que mesure le téléphone, tenu à `arm` m du
// poignet le long de l'axe visé (l'accéléromètre lit aussi les accélérations de la main) ; `sign` inverse
// l'accéléromètre, comme certains navigateurs.
function play(pointer, at, from, to, { arm = 0.1, sign = 1 } = {}) {
  const dt = 1 / 60;
  const pos = (t) => apply(at(t), [0, arm, 0]);
  for (let i = 0; i < Math.round((to - from) / dt); i++) {
    const t = from + i * dt;
    const D = matMul(transpose(at(t)), at(t + dt));
    const w = [D[2][1] - D[1][2], D[0][2] - D[2][0], D[1][0] - D[0][1]].map((c) => c / 2 / dt * 180 / Math.PI);
    const [p0, p1, p2] = [pos(t), pos(t + dt), pos(t + 2 * dt)];
    const acc = [0, 1, 2].map((j) => (p2[j] - 2 * p1[j] + p0[j]) / dt / dt);
    const accel = apply(transpose(at(t + dt)), [acc[0], acc[1], acc[2] + G]).map((c) => c * sign);
    pointer.update({ alpha: w[0], beta: w[1], gamma: w[2] }, accel, dt);
  }
  return pointer;
}
const diff = ([h1, e1], [h2, e2]) => [((h1 - h2 + 540) % 360) - 180, e1 - e2];
const close = (got, want, tolerance) =>
  want.forEach((w, i) => assert.ok(Math.abs(got[i] - w) < tolerance, `${got} ≠ ${want}`));

test('pointeur au gyroscope : tourner à gauche baisse le cap, lever le bout monte, retourné il s’inverse', () => {
  const pointer = gyroPointer();
  const at = (t) => pose(t < 2 ? 0 : -15 * Math.min(1, t - 2), 10 + (t < 4 ? 0 : 8 * Math.min(1, t - 4)), 0);
  play(pointer, at, 0, 2);
  const start = pointer.aim(0);
  play(pointer, at, 2, 4);
  close(diff(pointer.aim(0), start), [15, 0], 0.1); // ψ −15 : vers la droite
  play(pointer, at, 4, 6);
  close(diff(pointer.aim(0), start), [15, 8], 0.1);
  const flipped = diff(pointer.aim(180), pointer.aim(0));
  close([Math.abs(flipped[0]), flipped[1]], [180, -2 * pointer.aim(0)[1]], 1e-6);
});

test('pointeur au gyroscope : levé et roulé, un balayage reste droit', () => {
  const pointer = gyroPointer();
  const at = (t) => pose(30 * Math.max(0, t - 3), 25, 20);
  play(pointer, at, 0, 3);
  const start = pointer.aim(0);
  play(pointer, at, 3, 4);
  close(diff(pointer.aim(0), start), [-30, 0], 0.1);
});

test('pointeur au gyroscope : dix grands cercles rapides au bras, et la visée revient', () => {
  const pointer = gyroPointer();
  const w = 2 * Math.PI;
  const at = (t) => (t < 3 ? pose(0, 32, 0)
    : pose(25 * Math.sin(w * (t - 3)), 15 + 17 * Math.cos(w * (t - 3)), 12 * Math.sin(w * (t - 3) + 1)));
  play(pointer, at, 0, 3);
  const start = pointer.aim(0);
  // Cercles à 1 Hz, bras tendu : jusqu'à 0,65 g d'accélération de la main.
  play(pointer, at, 3, 13, { arm: 0.4 });
  close(diff(pointer.aim(0), start), [0, 0], 0.5);
});

test('pointeur au gyroscope : tenu debout au départ, puis pointé vers l’écran', () => {
  const pointer = gyroPointer();
  const at = (t) => pose(t < 3 ? 0 : -20 * Math.min(1, t - 3), t < 1 ? 90 : 90 - 80 * Math.min(1, t - 1), 0);
  play(pointer, at, 0, 2.5);
  const lowered = play(pointer, at, 2.5, 3).aim(0);
  play(pointer, at, 3, 4);
  close(diff(pointer.aim(0), lowered), [20, 0], 0.2);
  close([pointer.aim(0)[1]], [10], 0.5);
});

test('pointeur au gyroscope : accéléromètre de signe inversé, même visée une fois calibré', () => {
  const at = (t) => pose(t < 2 ? 0 : t < 3 ? 10 * (t - 2) : t < 4 ? 10 - 20 * (t - 3) : -10 + 10 * (t - 4),
    t < 2 ? 10 : t < 3 ? 10 + 5 * (t - 2) : t < 4 ? 15 - 10 * (t - 3) : 5 + 5 * (t - 4), 5);
  for (const sign of [1, -1]) {
    const pointer = gyroPointer();
    const aimAt = (t) => play(pointer, at, t - 1, t, { sign }).aim(0);
    play(pointer, at, 0, 2, { sign });
    const [topLeft, bottomRight, middle] = [aimAt(3), aimAt(4), aimAt(5)];
    close(aimPosition(middle, topLeft, bottomRight), [0, 0], 0.01);
  }
});
