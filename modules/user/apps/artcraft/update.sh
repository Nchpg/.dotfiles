#!/usr/bin/env bash
# Vérifie la dernière release GitHub d'ArtCraft Launcher (storytold/craft-launcher)
# et met à jour pinned.json avec l'URL et le hash SRI de l'AppImage x86_64,
# calculé via `nix store prefetch-file` pour que le hash corresponde à
# l'artefact réellement empaqueté.
# Seul le launcher est épinglé ici : les apps de la suite, il les installe et
# les met à jour lui-même dans ~/Applications (cf. default.nix).
# Protocole : cf. scripts/lib/update-module.sh.
set -euo pipefail
# shellcheck source=scripts/lib/update-module.sh
. "${MY_FLAKE:-$HOME/.dotfiles}/scripts/lib/update-module.sh"
um_init "$@"

echo "🔎 Checking latest ArtCraft Launcher release..."
version=$(um_latest_gh_release storytold/craft-launcher)
echo "Latest version: $version"

current=$(um_pinned version)
[ "$UM_CHECK" -eq 1 ] && um_check "ArtCraft Launcher" "$current" "$version" \
    "https://github.com/storytold/craft-launcher/releases/tag/v$version"
um_skip_if_current "ArtCraft Launcher" "$current" "$version"

url="https://github.com/storytold/craft-launcher/releases/download/v${version}/artcraft-launcher-${version}-linux-x86_64.AppImage"
echo "🔎 Fetching + hashing AppImage for $version..."
hash=$(um_prefetch_url "$url")
um_write_pinned version="$version" url="$url" hash="$hash"

echo "⬆️ Updated ArtCraft Launcher to version $version"
