// node --test motion.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { G, aimAngles, aimPosition, dpadDirections, holdAngle, toDSU, upFromOrientation, validCorners } from './web/motion.mjs';

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

test('croix tactile : secteurs, diagonales, centre mort, portée et interface tournée', () => {
  assert.deepEqual(dpadDirections(50, 0, 100, 0), ['right']);
  assert.deepEqual(dpadDirections(0, -50, 100, 0), ['up']);
  assert.deepEqual(dpadDirections(40, 40, 100, 0), ['right', 'down']);
  assert.deepEqual(dpadDirections(-40, -40, 100, 0), ['left', 'up']);
  assert.deepEqual(dpadDirections(5, 0, 100, 0), []); // pouce posé au centre
  assert.deepEqual(dpadDirections(115, 0, 100, 0), ['right']); // un peu hors du dessin : toléré
  assert.deepEqual(dpadDirections(130, 0, 100, 0), []); // trop loin
  // Interface tournée de 90° (horaire) : un doigt en bas de l'écran est à droite de la croix dessinée.
  assert.deepEqual(dpadDirections(0, 50, 100, 90), ['right']);
});

test('verticale tirée de l’orientation, dans le repère de la spec', () => {
  near(upFromOrientation(0, 0), [0, 0, 1]);
  near(upFromOrientation(90, 0), [0, 1, 0]);
  near(upFromOrientation(0, -90), [1, 0, 0]);
});
