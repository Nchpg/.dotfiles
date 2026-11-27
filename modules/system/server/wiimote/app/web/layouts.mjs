// Dispositions de la manette selon le jeu en cours, que le Dolphin corrigé annonce : son identifiant et, pour Mario
// Kart Wii, l'étape de la course. La première disposition dont tous les tags sont actifs l'emporte : la liste va de
// la plus précise à la plus générale, la dernière, sans tag, est la manette de base. Une disposition allume des
// options (classes du body), la mise en page elle-même reste dans le CSS (index.html) :
//   volant : en mode joystick, de côté, le joystick braque (1 ou 2 tenu) et le bouton Objet apparaît ;
//   verrou : de côté, le bouton qui garde 2 enfoncé (accélération automatique) ;
//   horizontal : tenue horizontale imposée, sans retour à la verticale (la Wiimote seule se tient ainsi en course).
export const LAYOUTS = [
  { tags: ['mario-kart', 'course'], volant: true, verrou: true, horizontal: true },
  { tags: [] },
];

// Jeux reconnus, par les trois premiers caractères de l'identifiant (le quatrième est la région : RMCP01, RMCE01…).
const GAMES = { RMC: 'mario-kart' };

// Tags du jeu en cours. `stage` : étape de la course + 1, 0 hors course (1 caméra d'intro, 2 décompte, 3 course,
// 4 arrivée, 5 terminée). La course compte dès l'intro, souvent sans doigt sur l'écran : la disposition change avant
// le départ, et revient à l'arrivée pour les menus de fin.
export function gameTags(game = '', stage = 0) {
  const tags = [];
  const name = GAMES[game.slice(0, 3)];
  if (name) tags.push(name);
  if (stage >= 1 && stage <= 3) tags.push('course');
  return tags;
}

export const layoutFor = (tags) => LAYOUTS.find((l) => l.tags.every((t) => tags.includes(t)));
