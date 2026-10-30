#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib/update-module.sh
. "${MY_FLAKE:-$HOME/.dotfiles}/scripts/lib/update-module.sh"
um_init "$@"

echo "🔎 Checking latest herdr release..."
version=$(um_latest_gh_release herdrdev/herdr)
echo "Latest version: $version"

current=$(um_pinned version)
[ "$UM_CHECK" -eq 1 ] && um_check herdr "$current" "$version" \
    "https://github.com/herdrdev/herdr/releases/tag/v$version"
um_skip_if_current herdr "$current" "$version"

url="https://github.com/herdrdev/herdr/releases/download/v${version}/herdr-linux-x86_64"
echo "🔎 Fetching + hashing binary for $version..."
hash=$(um_prefetch_url "$url")
um_write_pinned version="$version" url="$url" hash="$hash"

echo "⬆️ Updated herdr to version $version"
