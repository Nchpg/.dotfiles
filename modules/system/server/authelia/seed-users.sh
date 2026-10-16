# shellcheck shell=bash disable=SC2154 # live, seed : posés par le préambule Nix
set -euo pipefail

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

if [ -e "$live" ]; then
  # L'opérande de droite gagne : le fichier vivant passe en second.
  yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' \
    "$seed" "$live" > "$tmp"
else
  cp "$seed" "$tmp"
fi

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
