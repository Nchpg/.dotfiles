# shellcheck shell=bash disable=SC2154 # current, flake, profileFile, favoritesFile, galleryServer, browser : posés par le préambule Nix
# Corps de la commande `theme` (cf. default.nix à côté, qui le précède d'un
# préambule : variante actuelle, fichiers du dépôt que la galerie réécrit,
# serveur de galerie et navigateur épinglés dans le store, `flake`).

want="${1:-}"

# Sans argument : galerie servie en local (pas file://) pour que le
# bouton "appliquer" puisse réécrire le profil.
if [ -z "$want" ]; then
  # Pas de mkFlakeGuard : aucun script du dépôt n'est exécuté ici, ce
  # sont ces deux fichiers qu'il faut pouvoir écrire (contrôlés juste
  # en dessous).
  profile="$flake/$profileFile"
  favorites="$flake/$favoritesFile"
  for f in "$profile" "$favorites"; do
    if [ ! -w "$f" ]; then
      echo "theme : $f introuvable ou non modifiable." >&2
      exit 1
    fi
  done

  echo "Galerie des thèmes (variante actuelle : $current)"
  set +e
  THEME_BROWSER=$browser "$galleryServer" "$profile" "$favorites"
  rc=$?
  set -e
  # 2 = fermé sans rien appliquer : pas une erreur.
  [ "$rc" = 2 ] && exit 0
  [ "$rc" = 0 ] || exit "$rc"

  # Le rebuild vit ici (terminal) et pas dans le handler HTTP : il a
  # besoin de sudo.
  echo
  printf 'Rebuild maintenant ? [y/N] '
  read -r reply || reply=""
  case "$reply" in
    [yYoO]) exec rebuild ;;
    *) echo "Config modifiée. Lance \`rebuild\` quand tu veux l'appliquer." ;;
  esac
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
