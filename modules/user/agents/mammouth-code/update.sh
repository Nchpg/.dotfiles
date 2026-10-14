#!/usr/bin/env bash
# Vérifie la dernière release GitHub de Mammouth Code (mammouth-ai/code) et
# met à jour pinned.json avec l'URL et le hash SRI du tarball linux-x64,
# calculé via `nix store prefetch-file` pour que le hash corresponde à
# l'artefact réellement installé (binaire précompilé, pas de paquet npm ici).
# Protocole : cf. scripts/lib/update-module.sh.
set -euo pipefail
# shellcheck source=scripts/lib/update-module.sh
. "${MY_FLAKE:-$HOME/.dotfiles}/scripts/lib/update-module.sh"
um_init "$@"

echo "🔎 Checking latest Mammouth Code release..."
version=$(um_latest_gh_release mammouth-ai/code)
echo "Latest version: $version"

current=$(um_pinned version)
[ "$UM_CHECK" -eq 1 ] && um_check "Mammouth Code" "$current" "$version" \
    "https://github.com/mammouth-ai/code/releases/tag/v$version"
um_skip_if_current "Mammouth Code" "$current" "$version"

# linux-x64 (AVX2) uniquement : seule plateforme utilisée ici.
url="https://github.com/mammouth-ai/code/releases/download/v${version}/mammouth-linux-x64.tar.gz"
echo "🔎 Fetching + hashing tarball for $version..."
hash=$(um_prefetch_url "$url")
um_write_pinned version="$version" url="$url" hash="$hash"

echo "⬆️ Updated Mammouth Code to version $version"
