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

# Le secret fait foi : un compte qui n'y est plus quitte aussi le fichier vivant, avec son second
# facteur (sinon un compte recréé plus tard sous ce nom en hériterait). Jamais si le secret ne liste
# aucun compte : une lecture ratée effacerait tout le monde.
seeded=$(yq -r '(.users // {}) | keys | .[]' "$seed")
if [ -n "$seeded" ]; then
  for user in $(yq -r '(.users // {}) | keys | .[]' "$tmp"); do
    grep -qxF -- "$user" <<< "$seeded" && continue
    yq -i "del(.users.\"$user\")" "$tmp"
    if [ -f "$db" ]; then
      for table in totp_configurations webauthn_credentials webauthn_devices duo_devices user_preferences; do
        if [ -n "$(sqlite3 "$db" "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '$table'")" ]; then
          sqlite3 "$db" "DELETE FROM $table WHERE username = '${user//\'/\'\'}'"
        fi
      done
    fi
    echo "compte '$user' : retiré (absent du secret), second facteur compris"
  done
else
  echo "secret sans aucun compte : rien n'est retiré du fichier vivant" >&2
fi

install -m 0600 "$tmp" "$live"
