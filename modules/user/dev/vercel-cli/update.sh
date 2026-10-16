#!/usr/bin/env bash
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
