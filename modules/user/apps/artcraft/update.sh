#!/usr/bin/env bash
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
