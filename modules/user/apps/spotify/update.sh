#!/usr/bin/env bash
# Vérifie la dernière release GitHub de spotify-adblock (abba23/spotify-adblock)
# et met à jour pinned.json : hash des sources (`nix flake prefetch`, même
# hash NAR que fetchFromGitHub) et cargoHash, obtenu en construisant le
# vendoring des dépendances Rust avec un hash factice puis en relisant celui
# que Nix attendait.
# Lancé par update.sh (commande `update`, ou `rebuild -u`).
set -euo pipefail

# --check : affiche {name, current, latest, url} en JSON sur stdout, sans rien
# télécharger ni modifier. Utilisé par update.sh pour tout lister avant de
# choisir ; le reste des messages part alors sur stderr.
check=0
if [ "${1:-}" = "--check" ]; then
    check=1
    exec 3>&1 1>&2
fi

flake="${MY_FLAKE:-$HOME/.dotfiles}"
dir="$flake/modules/user/apps/spotify"
pinned_file="$dir/pinned.json"

echo "🔎 Checking latest spotify-adblock release..."
# Jeton facultatif (GITHUB_TOKEN, exporté par update.sh depuis gh ou par la
# CI) : sans lui l'API GitHub plafonne à 60 requêtes/h par IP, vite atteint
# sur un runner partagé.
auth=()
[ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
# jq -e + // empty : réponse inattendue (rate limit, pas de release) -> échec
# explicite ici plutôt qu'une version "null".
if ! version=$(curl -fsSL "${auth[@]}" "https://api.github.com/repos/abba23/spotify-adblock/releases/latest" \
    | jq -er '.tag_name // empty | ltrimstr("v")') || [ -z "$version" ]; then
    echo "⚠️ Error: Could not read latest spotify-adblock version" >&2
    exit 1
fi
echo "Latest version: $version"

if [ "$check" -eq 1 ]; then
    current=$(jq -r '.version // empty' "$pinned_file" 2>/dev/null || true)
    jq -nc --arg name "spotify-adblock" --arg current "$current" --arg latest "$version" \
        --arg url "https://github.com/abba23/spotify-adblock/releases/tag/v$version" '{$name, $current, $latest, $url}' >&3
    exit 0
fi

if [ -f "$pinned_file" ]; then
    current_version=$(jq -r '.version // empty' "$pinned_file" 2>/dev/null || echo "")
    if [ "$current_version" = "$version" ]; then
        echo "✓ spotify-adblock is already up to date ($version)"
        exit 0
    fi
fi

echo "🔎 Fetching + hashing sources for $version..."
if ! hash=$(nix flake prefetch --json "github:abba23/spotify-adblock/v${version}" 2>/dev/null \
    | jq -er '.hash'); then
    echo "⚠️ Error: Could not retrieve source hash for spotify-adblock" >&2
    exit 1
fi

echo "🔎 Computing cargoHash (vendoring Rust dependencies)..."
# Même fetcher que buildRustPackage pour cargoHash : le hash ne dépend que du
# contenu vendoré, pas du nom de la dérivation. nixpkgs = celui locké par le
# flake, pour vendorer avec la même version de l'outil.
expr="let
  flake = builtins.getFlake \"$flake\";
  pkgs = import flake.inputs.nixpkgs-stable { system = builtins.currentSystem; };
in pkgs.rustPlatform.fetchCargoVendor {
  src = pkgs.fetchFromGitHub {
    owner = \"abba23\";
    repo = \"spotify-adblock\";
    rev = \"v${version}\";
    hash = \"$hash\";
  };
  hash = pkgs.lib.fakeHash;
}"
# Échec attendu (hash factice) : le vrai hash est dans la ligne « got: ».
build_log=$(nix build --no-link --impure --expr "$expr" 2>&1 || true)
cargo_hash=$(printf '%s\n' "$build_log" | sed -n 's/^[[:space:]]*got:[[:space:]]*//p' | head -n 1)
if [ -z "$cargo_hash" ]; then
    echo "⚠️ Error: Could not compute cargoHash for spotify-adblock" >&2
    printf '%s\n' "$build_log" | tail -n 20 >&2
    exit 1
fi

cat <<EOT > "$pinned_file"
{
  "version": "$version",
  "hash": "$hash",
  "cargoHash": "$cargo_hash"
}
EOT

echo "⬆️ Updated spotify-adblock to version $version"
