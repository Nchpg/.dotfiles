#!/usr/bin/env bash
# Suit la PR btop #1457 : pinned.json sur le dernier commit de sa branche.
set -euo pipefail
# shellcheck source=scripts/lib/update-module.sh
. "${MY_FLAKE:-$HOME/.dotfiles}/scripts/lib/update-module.sh"
um_init "$@"

pr=1457
name="btop (PR #$pr · GPU xe)"

echo "🔎 Checking btop PR #$pr (Intel xe GPU support)..."
if ! pr_json=$(um_curl "https://api.github.com/repos/aristocratos/btop/pulls/$pr") \
    || ! state=$(printf '%s' "$pr_json" | jq -er '.state // empty'); then
    um_die "Could not read btop PR #$pr"
fi

current=$(um_pinned rev)

if [ "$(printf '%s' "$pr_json" | jq -r '.merged')" = "true" ]; then
    [ "$UM_CHECK" -eq 1 ] && um_check "$name" "${current:0:7}" "${current:0:7}" "" \
        "PR mergée : retirer l'override btopXe"
    echo "🎉 PR #$pr mergée : retirer btopXe de modules/user/tui/btop/default.nix"
    echo "   (et xeGpuSupport) dès que nixpkgs embarque une version de btop qui l'inclut."
    exit 0
fi
if [ "$state" != "open" ]; then
    [ "$UM_CHECK" -eq 1 ] && um_check "$name" "${current:0:7}" "${current:0:7}" "" \
        "PR fermée sans merge : override à réévaluer"
    echo "⚠️ PR #$pr fermée sans merge : override conservé tel quel, à réévaluer." >&2
    exit 0
fi

owner=$(printf '%s' "$pr_json" | jq -er '.head.repo.owner.login')
repo=$(printf '%s' "$pr_json" | jq -er '.head.repo.name')
rev=$(printf '%s' "$pr_json" | jq -er '.head.sha')
echo "Latest PR commit: $rev ($owner/$repo)"

if [ "$UM_CHECK" -eq 1 ]; then
    url=""
    [ -n "$current" ] && url="https://github.com/$owner/$repo/compare/${current}...${rev}"
    um_check "$name" "${current:0:7}" "${rev:0:7}" "$url" ""
fi
um_skip_if_current "btop PR #$pr" "$current" "$rev"

if ! date=$(um_curl "https://api.github.com/repos/$owner/$repo/commits/$rev" \
    | jq -er '.commit.committer.date[0:10]'); then
    um_die "Could not read commit date for $rev"
fi

echo "🔎 Fetching + hashing sources for ${rev:0:7}..."
hash=$(um_prefetch_gh "$owner/$repo" "$rev")
um_write_pinned version="pr$pr-$date-${rev:0:7}" owner="$owner" repo="$repo" rev="$rev" hash="$hash"

echo "⬆️ Updated btop PR #$pr to ${rev:0:7} ($date)"
