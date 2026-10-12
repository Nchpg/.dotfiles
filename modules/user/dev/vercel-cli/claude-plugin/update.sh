#!/usr/bin/env bash
# Le plugin Claude Code officiel de Vercel est distribue via la marketplace
# anthropics/claude-plugins-official, qui epingle elle-meme un commit precis
# de vercel/vercel-plugin (champ .source.sha). On suit CETTE marketplace, pas
# la branche main de vercel-plugin : c'est elle qui fait foi pour la version
# que `claude plugin install vercel@claude-plugins-official` installerait.
set -euo pipefail

# --check : affiche {name, current, latest, url} en JSON sur stdout, sans rien
# télécharger ni modifier. Utilisé par update.sh pour tout lister avant de
# choisir ; le reste des messages part alors sur stderr.
check=0
if [ "${1:-}" = "--check" ]; then
    check=1
    exec 3>&1 1>&2
fi

flake="${MY_FLAKE:-$HOME/.dotfiles}"
dir="$flake/modules/user/dev/vercel-cli/claude-plugin"
pinned_file="$dir/pinned.json"

echo "🔎 Checking latest Vercel plugin commit (claude-plugins-official marketplace)..."
marketplace=$(curl -fsSL "https://raw.githubusercontent.com/anthropics/claude-plugins-official/main/.claude-plugin/marketplace.json")
rev=$(jq -r '.plugins[] | select(.name == "vercel") | .source.sha' <<<"$marketplace")
if [ -z "$rev" ] || [ "$rev" = "null" ]; then
    echo "⚠️ Error: could not find the vercel plugin entry in the marketplace" >&2
    exit 1
fi
echo "Latest pinned commit: $rev"

if [ "$check" -eq 1 ]; then
    current=$(jq -r '.rev // empty' "$pinned_file" 2>/dev/null || true)
    url=""
    [ -n "$current" ] && url="https://github.com/vercel/vercel-plugin/compare/${current}...${rev}"
    jq -nc --arg current "${current:0:7}" --arg latest "${rev:0:7}" --arg url "$url" \
        '{name: "Vercel Claude plugin", $current, $latest, $url}' >&3
    exit 0
fi

if [ -f "$pinned_file" ]; then
    current_rev=$(jq -r '.rev // empty' "$pinned_file" 2>/dev/null || echo "")
    if [ "$current_rev" = "$rev" ]; then
        echo "✓ Vercel Claude plugin is already up to date ($rev)"
        exit 0
    fi
fi

echo "🔎 Fetching plugin.json for version + hashing the repo at $rev..."
version=$(curl -fsSL "https://raw.githubusercontent.com/vercel/vercel-plugin/${rev}/.claude-plugin/plugin.json" | jq -r '.version')
if [ -z "$version" ] || [ "$version" = "null" ]; then
    echo "⚠️ Error: could not read plugin.json at $rev" >&2
    exit 1
fi

if ! sha256=$(nix run nixpkgs#nix-prefetch-github -- vercel vercel-plugin --rev "$rev" 2>/dev/null | jq -er '.hash'); then
    echo "⚠️ Error: could not prefetch vercel-plugin at $rev" >&2
    exit 1
fi

pinned_at=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

cat <<EOF > "$pinned_file"
{
  "version": "$version",
  "rev": "$rev",
  "sha256": "$sha256",
  "pinnedAt": "$pinned_at"
}
EOF


echo "⬆️ Updated Vercel Claude plugin to version $version ($rev)"
