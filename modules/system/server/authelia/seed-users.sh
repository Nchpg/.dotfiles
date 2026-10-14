# shellcheck shell=bash disable=SC2154 # live, seed : posés par le préambule Nix
# Sème le fichier d'utilisateurs vivant d'Authelia depuis sops : ajoute ce qui
# manque, ne touche JAMAIS à ce qui existe.
#
# Corps du script seulement : le module (default.nix à côté) le précède d'un
# préambule qui pose `live` (fichier vivant) et `seed` (secret sops).
set -euo pipefail

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

if [ -e "$live" ]; then
  # L'ordre de fusion est significatif : l'opérande de DROITE gagne,
  # d'où le fichier vivant en second.
  yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' \
    "$seed" "$live" > "$tmp"
else
  cp "$seed" "$tmp"
fi

# Tout compte déclaré SANS mot de passe reçoit ici le haché d'un aléa que
# personne ne lit, pas même ce script. La personne entre par « mot de passe
# oublié » et pose le sien, qui survivra aux rebuilds grâce à la fusion
# ci-dessus. Ça retire les mots de passe de sops, où l'on ne déclare plus
# qu'une identité.
for user in $(yq -r '(.users // {}) | keys | .[]' "$tmp"); do
  current=$(yq -r ".users.\"$user\".password // \"\"" "$tmp")
  if [ -z "$current" ] || [ "$current" = "null" ]; then
    digest=$(authelia crypto hash generate argon2 --random \
      | sed -n 's/^Digest: //p')
    yq -i ".users.\"$user\".password = \"$digest\"" "$tmp"
    echo "compte '$user' : mot de passe initial aléatoire, à poser via « mot de passe oublié »"
  fi
done

install -m 0600 "$tmp" "$live"
