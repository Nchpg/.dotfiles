#!/usr/bin/env bash
# Vérifie la dernière version publiée de Vercel CLI sur le registre npm (celui
# qu'utilise réellement `npx`, cf. default.nix) et met à jour pinned.json avec
# l'URL et le hash SRI du tarball, calculé via `nix store prefetch-file` pour
# que le hash corresponde à l'artefact effectivement exécuté. Protocole : cf.
# scripts/lib/update-module.sh.
set -euo pipefail
# shellcheck source=scripts/lib/update-module.sh
. "${MY_FLAKE:-$HOME/.dotfiles}/scripts/lib/update-module.sh"
um_init "$@"

echo "🔎 Checking latest Vercel CLI version (npm registry)..."
version=$(um_latest_npm vercel)
echo "Latest version: $version"

current=$(um_pinned version)
[ "$UM_CHECK" -eq 1 ] && um_check "Vercel CLI" "$current" "$version" \
    "https://www.npmjs.com/package/vercel/v/$version"
um_skip_if_current "Vercel CLI" "$current" "$version"

url="https://registry.npmjs.org/vercel/-/vercel-${version}.tgz"
echo "🔎 Fetching + hashing tarball for $version..."
hash=$(um_prefetch_url "$url")
um_write_pinned version="$version" url="$url" hash="$hash"

echo "⬆️ Updated Vercel CLI to version $version"
