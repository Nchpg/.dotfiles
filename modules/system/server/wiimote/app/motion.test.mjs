// node --test motion.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { gameTags, layoutFor } from './web/layouts.mjs';
import { G, gyroPointer, dpadDirection, holdAngle, notOlder, oneEuro, stickDirections, tiltGain, wheelMotion, withShake, rumbleGrain, rumbleWave, wheelSteer, toDSU, screenFrom, turnTo, upFromOrientation } from './web/motion.mjs';

const near = (got, want) =>
  want.forEach((w, i) => assert.ok(Math.abs(got[i] - w) < 1e-9, `${got} ≠ ${want}`));
const close = (got, want, tolerance) =>
  want.forEach((w, i) => assert.ok(Math.abs(got[i] - w) < tolerance, `${got} ≠ ${want}`));

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

// Télé plate de `size` (largeur, hauteur, en m), centrée en `center` (m, vu de la main), face vers `facing` :
// direction de son point (X, Y) (de -1 à 1, y en haut) vue de la main.
const unit3 = (v) => v.map((c) => c / Math.hypot(...v));
const cross3 = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
function television(center, facing, [width, height]) {
  const n = unit3(facing);
  const right = unit3(cross3([0, 0, 1], n));
  const up = cross3(n, right);
  return (X, Y) => unit3(center.map((c, i) => c + (X * width / 2) * right[i] + (Y * height / 2) * up[i]));
}
const cornersOf = (at) => [at(-1, 1), at(1, 1), at(1, -1), at(-1, -1)];

test('calibrage aux quatre coins : position exacte sur l’écran, de face, de biais, de près, en hauteur, derrière soi', () => {
  const cases = [
    [[0, 2.5, 0.3], [0, -1, 0], [1.2, 0.68]], // de face, à 2,5 m
    [[1.2, 2.5, 0.2], [0, -1, 0], [1.2, 0.68]], // assis à 1,2 m sur le côté (deuxième joueur)
    [[0, 1, 0], [0, -1, 0], [1.6, 0.9]], // tout près d'une grande télé
    [[0, 2, 1.2], [0, -1, -0.4], [1, 0.56]], // fixée en hauteur, penchée vers soi
    [[-0.4, -2.5, 0.1], [0.2, 1, 0], [1.2, 0.68]], // derrière soi dans le repère du téléphone, de biais
  ];
  for (const [center, facing, size] of cases) {
    const at = television(center, facing, size);
    // Repère du pointeur en miroir : signes propres au navigateur.
    for (const mirror of [1, -1]) {
      const seen = (X, Y) => at(X, Y).map((c, i) => (i === 0 ? c * mirror : c));
      const tv = screenFrom(cornersOf(seen));
      for (const [X, Y] of [[0, 0], [-0.5, 0.5], [0.3, -0.8], [1, -1], [-0.99, 0.2], [0.7, 0.9]]) {
        close(tv(seen(X, Y)), [X, Y], 1e-9);
      }
      close(tv(seen(3, 2)), [1, 1], 1e-9); // hors de l'écran : bloqué au bord
    }
  }
  // Coins presque confondus (double appui) ou dans le désordre : refusés.
  const at = television([0, 2.5, 0], [0, -1, 0], [1.2, 0.68]);
  assert.equal(screenFrom([at(-1, 1), at(-0.99, 1), at(1, -1), at(-1, -1)]), null);
  assert.equal(screenFrom([at(-1, 1), at(1, -1), at(1, 1), at(-1, -1)]), null);
});

test('recentrage : la visée du milieu de l’écran ramenée à son centre, après une dérive du gyroscope', () => {
  const turn = turnTo(unit3([0.2, 1, 0.1]), unit3([-0.3, 0.9, 0.4]));
  close(turn(unit3([0.2, 1, 0.1])), unit3([-0.3, 0.9, 0.4]), 1e-12);
  const [p, q] = [unit3([1, 2, 3]), unit3([-2, 0.5, 1])];
  close([turn(p).reduce((s, c, i) => s + c * turn(q)[i], 0)], [p.reduce((s, c, i) => s + c * q[i], 0)], 1e-12);
  // Aux coins, l'écart que laisse un recentrage à un seul point : 2 % face à la télé, 5 % sous une télé fixée haut
  // (visée à 30° au-dessus de l'horizon), où une dérive du cap déforme davantage. Un recalibrage fait mieux.
  const setups = [[[0, 2.5, 0.3], [0, -1, 0], 0.02], [[1.2, 2.5, 0.2], [0, -1, 0], 0.02], [[0, 2, 1.2], [0, -1, -0.4], 0.05]];
  for (const [center, facing, tolerance] of setups) {
    const at = television(center, facing, [1.2, 0.68]);
    const tv = screenFrom(cornersOf(at));
    close(tv(tv.center), [0, 0], 1e-9);
    // Le gyroscope a tourné la visée de 3° en cap et 1° en élévation depuis le calibrage : on vise le milieu, ⌖.
    const [yaw, pitch] = [3 * Math.PI / 180, Math.PI / 180];
    const drift = (v) => {
      const w = [v[0] * Math.cos(yaw) - v[1] * Math.sin(yaw), v[0] * Math.sin(yaw) + v[1] * Math.cos(yaw), v[2]];
      return [w[0], w[1] * Math.cos(pitch) - w[2] * Math.sin(pitch), w[1] * Math.sin(pitch) + w[2] * Math.cos(pitch)];
    };
    const recentre = turnTo(drift(at(0, 0)), tv.center);
    close(tv(recentre(drift(at(0, 0)))), [0, 0], 1e-9);
    for (const [X, Y] of [[-0.9, 0.9], [0.9, 0.9], [0.9, -0.9], [-0.9, -0.9], [0.5, -0.2]]) {
      close(tv(recentre(drift(at(X, Y)))), [X, Y], tolerance);
    }
  }
});

test('calibrage aux quatre coins : visée très loin de l’écran, le pointeur reste fini et dans l’écran', () => {
  const tv = screenFrom(cornersOf(television([1.2, 2.5, 0.2], [0, -1, 0], [1.2, 0.68])));
  for (const v of [[0, -1, 0], [1, 0, 0], [-1, 0, 0], [0, 0, 1], [0, 0, -1], [0.6, 0.1, -0.8]]) {
    assert.ok(tv(v).every((c) => Number.isFinite(c) && Math.abs(c) <= 1), `${v}`);
  }
});

test('numéros de vibration : le même ou plus récent, modulo 256', () => {
  assert.ok(notOlder(3, null));
  assert.ok(notOlder(5, 5)); // renvoi
  assert.ok(notOlder(6, 5));
  assert.ok(!notOlder(4, 5)); // en retard
  assert.ok(notOlder(0, 255)); // après 255 vient 0
  assert.ok(!notOlder(255, 0));
  assert.ok(notOlder(132, 5) && !notOlder(134, 5)); // au-delà de 127 d'avance : pris pour un retard
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
  assert.equal(dpadDirection(300, 0, 100, 0, Infinity), 'right'); // posé sur la croix puis sorti : gardée
  // Interface tournée de 90° (horaire) : un doigt en bas de l'écran est à droite de la croix dessinée.
  assert.equal(dpadDirection(0, 50, 100, 90), 'right');
});

test('volant au joystick : braquage fin au centre, sans saut, plein au bout', () => {
  const reach = 100;
  assert.equal(wheelSteer(0, reach), 0);
  assert.equal(wheelSteer(9, reach), 0); // zone morte
  assert.ok(Math.abs(wheelSteer(10.5, reach)) < 0.005); // pas de saut à sa sortie
  assert.equal(wheelSteer(100, reach), 1);
  assert.equal(wheelSteer(-250, reach), -1); // pouce hors du socle : plein braquage
  assert.equal(wheelSteer(-40, reach), -wheelSteer(40, reach));
  // Au centre, deux fois moins sensible que la course linéaire ; au bout, plus.
  const linear = (lx) => (lx / reach - 0.1) / 0.9;
  assert.ok(Math.abs(wheelSteer(20, reach) / linear(20) - 0.5) < 0.01);
  assert.ok(wheelSteer(95, reach) - wheelSteer(90, reach) > linear(95) - linear(90));
  // Croissant partout.
  for (let lx = 0; lx < 100; lx++) assert.ok(wheelSteer(lx + 1, reach) >= wheelSteer(lx, reach));
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

test('vibration : relancée en cours de route, elle reprend son rythme sans le casser', () => {
  // Milliseconde par milliseconde : 1 si le moteur vibre.
  const timeline = (pattern) => pattern.flatMap((ms, i) => Array(ms).fill(i % 2 === 0 ? 1 : 0));
  assert.deepEqual(rumbleWave(10, 0, 40), [10, 10, 10, 10]);
  assert.deepEqual(rumbleWave(20, 57, 300), [300]); // continue
  assert.deepEqual(rumbleWave(10, 40.3, 40).slice(0, 2), [10, 10]); // phase de performance.now(), arrondie
  const whole = timeline(rumbleWave(7, 0, 800));
  for (const phase of [0, 3, 7, 13, 19, 40, 251]) {
    const resumed = timeline(rumbleWave(7, phase, 300));
    assert.ok(resumed.length >= 300, `couvre l'horizon (phase ${phase})`);
    assert.deepEqual(resumed, whole.slice(phase, phase + resumed.length), `phase ${phase}`);
  }
});

test('vibration longue au grain fin : même force, rythme continu, impulsions d\'au moins 4 ms', () => {
  const timeline = (pattern) => pattern.flatMap((ms, i) => Array(ms).fill(i % 2 === 0 ? 1 : 0));
  const share = (bits) => bits.reduce((a, b) => a + b, 0) / bits.length;
  assert.deepEqual(rumbleWave(10, 0, 40, 10), [5, 5, 5, 5, 5, 5, 5, 5]);
  assert.deepEqual(rumbleWave(15, 0, 40, 10), [8, 2, 7, 3, 8, 2, 7, 3]); // 75 % pile, en alternance
  for (const on of [8, 11, 15, 19]) {
    const whole = timeline(rumbleWave(on, 0, 1000, 10));
    close([share(whole.slice(0, 1000))], [on / 20], 0.011);
    for (const phase of [0, 3, 10, 17, 251]) {
      const resumed = timeline(rumbleWave(on, phase, 300, 10));
      assert.deepEqual(resumed, whole.slice(phase, phase + resumed.length), `${on} sur 20, phase ${phase}`);
    }
  }
  assert.equal(rumbleGrain(7), 20); // impulsions de 3,5 ms : trop courtes, grain d'origine
  assert.equal(rumbleGrain(8), 10);
});

test('volant au joystick : une secousse franche passe, pas les petits à-coups de la main', () => {
  const wheel = wheelMotion(0.5);
  assert.deepEqual(withShake(wheel, [0.2, -0.3, 0.1]), wheel);
  near(withShake(wheel, [0, -2, 0.5]), [wheel[0], wheel[1] - 2, wheel[2] + 0.5, 0, 0, 0]);
});

test('dispositions : volant, verrou et tenue horizontale seulement en course de Mario Kart, toutes régions', () => {
  const extras = (game, stage) => {
    const l = layoutFor(gameTags(game, stage));
    return [Boolean(l.volant), Boolean(l.verrou), Boolean(l.horizontal)];
  };
  assert.deepEqual(extras('RMCP01', 3), [true, true, true]);
  assert.deepEqual(extras('RMCE01', 2), [true, true, true]); // décompte
  assert.deepEqual(extras('RMCJ01', 0), [false, false, false]); // menus
  assert.deepEqual(extras('RMCK01', 5), [false, false, false]); // course terminée : menus de fin
  assert.deepEqual(extras('RSBE01', 3), [false, false, false]); // autre jeu
  assert.deepEqual(extras('', 0), [false, false, false]); // pas de jeu, ou Dolphin sans le correctif
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

// Joue une trajectoire (pose à l'instant t, en s) de `from` à `to`, échantillonnée à 60 Hz comme un vrai capteur :
// rotation à l'instant de l'échantillon.
function play(pointer, at, from, to) {
  for (let i = 1; i <= Math.round((to - from) * 60); i++) {
    const t = from + i / 60;
    const h = 1e-4;
    const D = matMul(transpose(at(t - h)), at(t + h));
    const w = [D[2][1] - D[1][2], D[0][2] - D[2][0], D[1][0] - D[0][1]].map((c) => c / 4 / h * 180 / Math.PI);
    pointer.update({ alpha: w[0], beta: w[1], gamma: w[2] }, t * 1000);
  }
  return pointer;
}
// Départ et arrivée en douceur, comme une main.
const ease = (x) => (x <= 0 ? 0 : x >= 1 ? 1 : x * x * (3 - 2 * x));

// [cap vers la droite, élévation] de la visée, pour vérifier les mouvements. Le repère fixe du pointeur est celui du
// téléphone au premier échantillon : la verticale y est la dernière ligne de cette pose ; cap compté depuis l'axe le
// plus horizontal.
function aimOf(pointer, first, hold = 0) {
  const [f, u] = [pointer.direction(hold), first[2]];
  const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  const axis = [[1, 0, 0], [0, 1, 0], [0, 0, 1]].reduce((a, b) => (Math.abs(dot(a, u)) <= Math.abs(dot(b, u)) ? a : b));
  const n = axis.map((c, i) => c - dot(axis, u) * u[i]);
  const east = cross3(n, u);
  return [Math.atan2(dot(f, east), dot(f, n)) * 180 / Math.PI, Math.asin(dot(f, u)) * 180 / Math.PI];
}
const diff = ([h1, e1], [h2, e2]) => [((h1 - h2 + 540) % 360) - 180, e1 - e2];

test('pointeur au gyroscope : tourner à gauche baisse le cap, lever le bout monte, retourné il s’inverse', () => {
  const pointer = gyroPointer();
  const at = (t) => pose(-15 * ease(t - 2), 10 + 8 * ease(t - 4), 0);
  play(pointer, at, 0, 2);
  const start = aimOf(pointer, at(0));
  play(pointer, at, 2, 4);
  close(diff(aimOf(pointer, at(0)), start), [15, 0], 0.01); // ψ −15 : vers la droite
  play(pointer, at, 4, 6);
  close(diff(aimOf(pointer, at(0)), start), [15, 8], 0.01);
  close(pointer.direction(180), pointer.direction(0).map((c) => -c), 1e-12);
});

test('pointeur au gyroscope : un échantillon vide ou invalide est ignoré', () => {
  const pointer = gyroPointer();
  pointer.update({ alpha: 0, beta: 0, gamma: 0 }, 0);
  pointer.update({ alpha: null, beta: 0, gamma: 0 }, 16);
  pointer.update({ alpha: NaN, beta: 1, gamma: 2 }, 33);
  pointer.update({ alpha: 0, beta: 0, gamma: 0 }, Infinity);
  pointer.update({ alpha: 0, beta: 0, gamma: 30 }, 50);
  assert.ok(pointer.direction(0).every(Number.isFinite));
});

test('pointeur au gyroscope : levé et roulé, un balayage reste droit', () => {
  const pointer = gyroPointer();
  const at = (t) => pose(30 * ease(t - 3), 25, 20);
  play(pointer, at, 0, 3);
  const start = aimOf(pointer, at(0));
  play(pointer, at, 3, 4);
  close(diff(aimOf(pointer, at(0)), start), [-30, 0], 0.01);
});

test('pointeur au gyroscope : dix grands cercles rapides, et la visée revient', () => {
  const pointer = gyroPointer();
  const w = 2 * Math.PI;
  // Cercles à 1 Hz lancés en douceur (une demi-seconde), roulis de la main compris.
  const at = (t) => {
    const [a, c] = [ease((t - 3) / 0.5), w * Math.max(0, t - 3)];
    return pose(25 * a * Math.sin(c), 32 - 17 * a * (1 - Math.cos(c)), 12 * a * Math.sin(c));
  };
  play(pointer, at, 0, 3);
  const start = pointer.direction(0);
  play(pointer, at, 3, 13);
  const end = pointer.direction(0);
  // Même direction à 0,03° près.
  const drift = Math.acos(Math.min(1, end.reduce((s, c, i) => s + c * start[i], 0))) * 180 / Math.PI;
  assert.ok(drift < 0.03, `${drift}°`);
});

test('pointeur au gyroscope : tenu debout au départ, puis pointé vers l’écran', () => {
  const pointer = gyroPointer();
  const at = (t) => pose(-20 * ease(t - 3), 90 - 80 * ease(t - 1), 0);
  const lowered = aimOf(play(pointer, at, 0, 3), at(0));
  play(pointer, at, 3, 4);
  close(diff(aimOf(pointer, at(0)), lowered), [20, 0], 0.05);
  close([aimOf(pointer, at(0))[1]], [10], 0.05);
});

// Session de jeu simulée de bout en bout, reproductible (`seed`) : joueur n'importe où face à la télé (de 1,2 à
// 3,5 m, jusqu'à 1,5 m sur le côté, télé de 80 cm à 1,6 m), téléphone tenu debout puis pointé, calibrage aux quatre
// coins, puis visée au hasard dans l'écran et au-delà en roulant la main. Rend l'écart au vrai point visé, en pixels
// d'un écran 1 920 × 1 080 : le pire et la moyenne quadratique.
function random(seed) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
function session({ seed, seconds = 60, gyroNoise = 0, jitter = 0, drop = 0 }) {
  const rnd = random(seed);
  const gauss = () => Math.sqrt(-2 * Math.log(1 - rnd())) * Math.cos(2 * Math.PI * rnd());
  const smooth = (amplitude, maxHz) => {
    const parts = Array.from({ length: 5 }, () => [(amplitude / 2.5) * (0.3 + rnd()), 2 * Math.PI * (0.05 + rnd() * maxHz), 2 * Math.PI * rnd()]);
    return (t) => parts.reduce((s, [a, w, p]) => s + a * Math.sin(w * t + p), 0);
  };
  const mix = (a, b, k) => a.map((c, i) => c + (b[i] - c) * k);
  const width = 0.8 + 0.8 * rnd();
  const spin = 2 * Math.PI * rnd();
  const seat = [3 * (rnd() - 0.5), 1.2 + 2.3 * rnd(), 0.8 * (rnd() - 0.5)];
  const at = (X, Y) => {
    const v = television(seat, [0, -1, 0], [width, (width * 9) / 16])(X, Y);
    return [v[0] * Math.cos(spin) - v[1] * Math.sin(spin), v[0] * Math.sin(spin) + v[1] * Math.cos(spin), v[2]];
  };
  const [sx, sy, roll] = [smooth(1.3, 0.8), smooth(1.3, 0.8), smooth(25, 0.5)];
  const anglesOf = ([x, y, z]) => [(Math.atan2(-x, y) * 180) / Math.PI, (Math.asin(z) * 180) / Math.PI];
  const upright = [anglesOf(at(0, 0))[0] + 40 * (rnd() - 0.5), 70];
  // Coins visés dans l'ordre, appui au milieu de chaque arrêt d'une demi-seconde.
  const stops = [[-1, 1], [1, 1], [1, -1], [-1, -1]];
  const target = (t) => {
    let from = [0, 0];
    for (let i = 0; i < 4; i++) {
      const start = 3 + 1.5 * i;
      if (t < start + 1) return mix(from, stops[i], ease(t - start));
      if (t < start + 1.5) return stops[i];
      from = stops[i];
    }
    return mix(from, [sx(t), sy(t)], ease((t - 9) / 0.5));
  };
  const angles = (t) => {
    if (t >= 3) return anglesOf(at(...target(t)));
    const [a, b] = [[upright[0] + 5 * Math.sin(t), upright[1]], anglesOf(at(0, 0))];
    const k = ease(t - 2);
    return [a[0] + ((((b[0] - a[0] + 180) % 360) + 360) % 360 - 180) * k, a[1] + (b[1] - a[1]) * k];
  };
  const R = (t) => {
    const [psi, e] = angles(t);
    return pose(psi, e, roll(t) * ease(t - 3));
  };
  const pointer = gyroPointer();
  const corners = [];
  let tv = null;
  let [worst, sum, count] = [0, 0, 0];
  for (let k = 1; k <= seconds * 60; k++) {
    const t = k / 60;
    if (rnd() < drop) continue;
    const h = 1e-4;
    const D = matMul(transpose(R(t - h)), R(t + h));
    const w = [D[2][1] - D[1][2], D[0][2] - D[2][0], D[1][0] - D[0][1]].map((c) => (c / 4 / h) * 180 / Math.PI + gyroNoise * gauss());
    pointer.update({ alpha: w[0], beta: w[1], gamma: w[2] }, t * 1000 + jitter * 2 * (rnd() - 0.5));
    if (corners.length < 4 && t >= 4.3 + 1.5 * corners.length - 1e-9) corners.push(pointer.direction(0));
    if (corners.length === 4 && !tv) tv = screenFrom(corners);
    if (t > 9.5 && tv) {
      const [X, Y] = tv(pointer.direction(0));
      const [x, y] = target(t).map((c) => Math.max(-1, Math.min(1, c)));
      const error = Math.hypot((X - x) * 960, (Y - y) * 540);
      [worst, sum, count] = [Math.max(worst, error), sum + error * error, count + 1];
    }
  }
  assert.ok(tv, `calibrage refusé (graine ${seed})`);
  return { worst, rms: Math.sqrt(sum / count) };
}

test('simulation de bout en bout : sans bruit de capteur, à 3 px près, où qu’on soit assis', () => {
  for (let seed = 1; seed <= 10; seed++) {
    const { worst } = session({ seed });
    assert.ok(worst < 3, `graine ${seed} : ${worst} px`);
  }
});

test('simulation de bout en bout : capteurs réels (gyroscope bruité, évènements décalés de ±1 ms, 2 % perdus)', () => {
  let rms = 0;
  for (let seed = 1; seed <= 10; seed++) {
    const r = session({ seed, gyroNoise: 0.05, jitter: 1, drop: 0.02 });
    assert.ok(r.worst < 35, `graine ${seed} : ${r.worst} px au pire`);
    rms += r.rms / 10;
  }
  assert.ok(rms < 8, `${rms} px en moyenne quadratique`);
});
