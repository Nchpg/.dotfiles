#!/usr/bin/env bash
# `theme` : change de thème (galerie) ou de variante dark/light. Installé
# seulement avec Stylix (cf. scripts/default.nix).
#
#   theme                  galerie servie en local : appliquer un thème
#                          réécrit le profil de CETTE cible (darkTheme /
#                          lightTheme), les favoris vivent dans
#                          themes/gallery/favorites.json — versionnés,
#                          sélection personnelle et non état système
#   theme dark|light|toggle  rebuild dans cette variante
set -euo pipefail

# Dépôt, cible et variante actuelles, galerie et navigateur figés au build :
# cf. lib/env.sh. confirm : cf. lib/ui.sh.
here="$(dirname "$0")"
# shellcheck source=scripts/lib/env.sh
. "$here/lib/env.sh"
# shellcheck source=scripts/lib/ui.sh
. "$here/lib/ui.sh"

current="${DOTS_VARIANT:-dark}"

want="${1:-}"

# Sans argument : galerie servie en local (pas file://) pour que le
# bouton "appliquer" puisse réécrire le profil.
if [ -z "$want" ]; then
  # Pas de require_flake : ce sont ces deux fichiers du dépôt qu'il faut
  # pouvoir écrire, contrôlés juste en dessous.
  profile="$flake/profiles/$DOTS_PROFILE/default.nix"
  favorites="$flake/themes/gallery/favorites.json"
  for f in "$profile" "$favorites"; do
    if [ ! -w "$f" ]; then
      echo "theme : $f introuvable ou non modifiable." >&2
      exit 1
    fi
  done

  echo "Galerie des thèmes (variante actuelle : $current)"
  set +e
  THEME_BROWSER="$DOTS_BROWSER" "$DOTS_GALLERY" "$profile" "$favorites"
  rc=$?
  set -e
  # 2 = fermé sans rien appliquer : pas une erreur.
  [ "$rc" = 2 ] && exit 0
  [ "$rc" = 0 ] || exit "$rc"

  # Le rebuild vit ici (terminal) et pas dans le handler HTTP : il a
  # besoin de sudo.
  echo
  if confirm "Rebuild maintenant ?"; then exec rebuild; fi
  echo "Config modifiée. Lance \`rebuild\` quand tu veux l'appliquer."
  exit 0
fi

if [ "$want" = "toggle" ]; then
  if [ "$current" = "dark" ]; then want=light; else want=dark; fi
fi

case "$want" in
  dark|light) ;;
  *)
    echo "usage: theme [dark|light|toggle]   (variante actuelle : $current)" >&2
    echo "       sans argument : ouvre la galerie des thèmes" >&2
    exit 1
    ;;
esac

if [ "$want" = "$current" ]; then
  echo "Déjà en $want — rien à faire."
  exit 0
fi

echo "→ bascule $current → $want…"
exec rebuild --variant "$want"
