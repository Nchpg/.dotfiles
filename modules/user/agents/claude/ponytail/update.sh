#!/usr/bin/env bash
# Plugin Claude Code ponytail : suit main de DietrichGebert/ponytail.
set -euo pipefail
# shellcheck source=scripts/lib/update-module.sh
. "${MY_FLAKE:-$HOME/.dotfiles}/scripts/lib/update-module.sh"
um_init "$@"

repo=DietrichGebert/ponytail
echo "🔎 Checking latest ponytail commit..."
if ! rev=$(um_curl "https://api.github.com/repos/$repo/commits/main" | jq -er '.sha // empty') || [ -z "$rev" ]; then
    um_die "could not read the latest ponytail commit"
fi

current=$(um_pinned rev)
if [ "$UM_CHECK" -eq 1 ]; then
    url=""
    [ -n "$current" ] && url="https://github.com/$repo/compare/${current}...${rev}"
    um_check "ponytail Claude plugin" "${current:0:7}" "${rev:0:7}" "$url"
fi
um_skip_if_current "ponytail Claude plugin" "$current" "$rev"

if ! version=$(um_curl "https://raw.githubusercontent.com/$repo/${rev}/.claude-plugin/plugin.json" \
    | jq -er '.version // empty') || [ -z "$version" ]; then
    um_die "could not read plugin.json at $rev"
fi
hash=$(um_prefetch_gh "$repo" "$rev")

um_write_pinned version="$version" rev="$rev" hash="$hash" \
    pinnedAt="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"

echo "⬆️ Updated ponytail Claude plugin to version $version ($rev)"
