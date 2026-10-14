#!/usr/bin/env bash
# Vérifie la dernière release GitHub de spotify-adblock (abba23/spotify-adblock)
# et met à jour pinned.json : hash des sources (`nix flake prefetch`, même
# hash NAR que fetchFromGitHub) et cargoHash, obtenu en construisant le
# vendoring des dépendances Rust avec un hash factice puis en relisant celui
# que Nix attendait. Protocole : cf. scripts/lib/update-module.sh.
set -euo pipefail
# shellcheck source=scripts/lib/update-module.sh
. "${MY_FLAKE:-$HOME/.dotfiles}/scripts/lib/update-module.sh"
um_init "$@"

echo "🔎 Checking latest spotify-adblock release..."
version=$(um_latest_gh_release abba23/spotify-adblock)
echo "Latest version: $version"

current=$(um_pinned version)
[ "$UM_CHECK" -eq 1 ] && um_check "spotify-adblock" "$current" "$version" \
    "https://github.com/abba23/spotify-adblock/releases/tag/v$version"
um_skip_if_current "spotify-adblock" "$current" "$version"

echo "🔎 Fetching + hashing sources for $version..."
hash=$(um_prefetch_gh abba23/spotify-adblock "v${version}")

echo "🔎 Computing cargoHash (vendoring Rust dependencies)..."
# Même fetcher que buildRustPackage pour cargoHash : le hash ne dépend que du
# contenu vendoré, pas du nom de la dérivation. nixpkgs = celui locké par le
# flake, pour vendorer avec la même version de l'outil.
expr="let
  flake = builtins.getFlake \"$UM_FLAKE\";
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
    printf '%s\n' "$build_log" | tail -n 20 >&2
    um_die "Could not compute cargoHash for spotify-adblock"
fi
um_write_pinned version="$version" hash="$hash" cargoHash="$cargo_hash"

echo "⬆️ Updated spotify-adblock to version $version"
