#!/usr/bin/env bash
# Suit le commit épinglé par la marketplace claude-plugins-official (.source.sha), pas main.
set -euo pipefail
# shellcheck source=scripts/lib/update-module.sh
. "${MY_FLAKE:-$HOME/.dotfiles}/scripts/lib/update-module.sh"
um_init "$@"

echo "🔎 Checking latest Vercel plugin commit (claude-plugins-official marketplace)..."
if ! rev=$(um_curl "https://raw.githubusercontent.com/anthropics/claude-plugins-official/main/.claude-plugin/marketplace.json" \
    | jq -er '.plugins[] | select(.name == "vercel") | .source.sha // empty') || [ -z "$rev" ]; then
    um_die "could not find the vercel plugin entry in the marketplace"
fi
echo "Latest pinned commit: $rev"

current=$(um_pinned rev)
if [ "$UM_CHECK" -eq 1 ]; then
    url=""
    [ -n "$current" ] && url="https://github.com/vercel/vercel-plugin/compare/${current}...${rev}"
    um_check "Vercel Claude plugin" "${current:0:7}" "${rev:0:7}" "$url"
fi
um_skip_if_current "Vercel Claude plugin" "$current" "$rev"

echo "🔎 Fetching plugin.json for version + hashing the repo at $rev..."
if ! version=$(um_curl "https://raw.githubusercontent.com/vercel/vercel-plugin/${rev}/.claude-plugin/plugin.json" \
    | jq -er '.version // empty') || [ -z "$version" ]; then
    um_die "could not read plugin.json at $rev"
fi
hash=$(um_prefetch_gh vercel/vercel-plugin "$rev")

um_write_pinned version="$version" rev="$rev" hash="$hash" \
    pinnedAt="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"

echo "⬆️ Updated Vercel Claude plugin to version $version ($rev)"
