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

# Compilé depuis les sources (cf. default.nix) : hash de l'archive du tag.
echo "🔎 Fetching + hashing source for $version..."
hash=$(um_prefetch_gh herdrdev "herdr/v$version")
um_write_pinned version="$version" hash="$hash"
echo "⚠️ toggle-tab-bar.patch : le rebuild échoue si les fichiers patchés ont changé (empreintes dans default.nix)."

echo "⬆️ Updated herdr to version $version"
