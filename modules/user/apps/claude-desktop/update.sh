#!/usr/bin/env bash
# Vérifie la dernière version de Claude Desktop dans le dépôt apt d'Anthropic
# et met à jour pinned.json avec l'URL et le hash SRI du .deb amd64, calculé
# via `nix store prefetch-file` pour que le hash corresponde à l'artefact
# réellement empaqueté. Protocole : cf. scripts/lib/update-module.sh.
set -euo pipefail
# shellcheck source=scripts/lib/update-module.sh
. "${MY_FLAKE:-$HOME/.dotfiles}/scripts/lib/update-module.sh"
um_init "$@"

repo="https://downloads.claude.ai/claude-desktop/apt/stable"

echo "🔎 Checking latest Claude Desktop release..."
# Index apt : une entrée par version publiée, on garde la plus récente.
# Index illisible ou vide -> échec explicite ici plutôt qu'une URL ..._amd64.deb
# sans version.
if ! version=$(um_curl "$repo/dists/stable/main/binary-amd64/Packages" \
    | sed -n 's/^Version: //p' | sort -V | tail -n 1) || [ -z "$version" ]; then
    um_die "Could not read latest Claude Desktop version"
fi
echo "Latest version: $version"

current=$(um_pinned version)
[ "$UM_CHECK" -eq 1 ] && um_check "Claude Desktop" "$current" "$version" ""
um_skip_if_current "Claude Desktop" "$current" "$version"

url="$repo/pool/main/c/claude-desktop/claude-desktop_${version}_amd64.deb"
echo "🔎 Fetching + hashing .deb for $version..."
hash=$(um_prefetch_url "$url")
um_write_pinned version="$version" url="$url" hash="$hash"

echo "⬆️ Updated Claude Desktop to version $version"
