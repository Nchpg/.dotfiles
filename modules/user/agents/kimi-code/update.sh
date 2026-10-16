#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib/update-module.sh
. "${MY_FLAKE:-$HOME/.dotfiles}/scripts/lib/update-module.sh"
um_init "$@"

echo "🔎 Checking latest Kimi Code version (npm registry)..."
version=$(um_latest_npm "@moonshot-ai/kimi-code")
echo "Latest version: $version"

current=$(um_pinned version)
[ "$UM_CHECK" -eq 1 ] && um_check "Kimi Code" "$current" "$version" \
    "https://www.npmjs.com/package/@moonshot-ai/kimi-code/v/$version"
um_skip_if_current "Kimi Code" "$current" "$version"

url="https://registry.npmjs.org/@moonshot-ai/kimi-code/-/kimi-code-${version}.tgz"
echo "🔎 Fetching + hashing tarball for $version..."
hash=$(um_prefetch_url "$url")
um_write_pinned version="$version" url="$url" hash="$hash"

echo "⬆️ Updated Kimi Code to version $version"
