#!/usr/bin/env bash
# Herdr app et herdr-core : manifestes de releases.herdr.dev (pas de release GitHub).
set -euo pipefail
# shellcheck source=scripts/lib/update-module.sh
. "${MY_FLAKE:-$HOME/.dotfiles}/scripts/lib/update-module.sh"
um_init "$@"

target=linux-x86_64

echo "🔎 Checking latest Herdr app and herdr-core..."
app=$(um_curl https://releases.herdr.dev/app/latest.json) || um_die "could not read the Herdr app manifest"
core=$(um_curl https://releases.herdr.dev/core/latest.json) || um_die "could not read the herdr-core manifest"
version=$(printf '%s' "$app" | jq -er '.version')
core_version=$(printf '%s' "$core" | jq -er '.version')
echo "Latest versions: app $version, core $core_version"

current="$(um_pinned version) / $(um_pinned core_version)"
latest="$version / $core_version"
[ "$UM_CHECK" -eq 1 ] && um_check "herdr app / core" "$current" "$latest" "https://herdr.dev"
um_skip_if_current "herdr app / core" "$current" "$latest"

url=$(printf '%s' "$app" | jq -er --arg t "$target" '.targets[$t].url')
core_url=$(printf '%s' "$core" | jq -er --arg t "$target" '.targets[$t].url')
echo "🔎 Fetching + hashing archives..."
hash=$(um_prefetch_url "$url")
core_hash=$(um_prefetch_url "$core_url")
um_write_pinned version="$version" url="$url" hash="$hash" \
    core_version="$core_version" core_url="$core_url" core_hash="$core_hash"

echo "⬆️ Updated Herdr app to $version, herdr-core to $core_version"
