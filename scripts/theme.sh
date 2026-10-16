#!/usr/bin/env bash
set -euo pipefail

here="$(dirname "$0")"
# shellcheck source=scripts/lib/env.sh
. "$here/lib/env.sh"
# shellcheck source=scripts/lib/ui.sh
. "$here/lib/ui.sh"

current="${DOTS_VARIANT:-dark}"

want="${1:-}"

if [ -z "$want" ]; then
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

  # Rebuild ici et non dans le serveur HTTP : il a besoin de sudo.
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
