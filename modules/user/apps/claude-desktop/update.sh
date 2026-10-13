#!/usr/bin/env bash
# Vérifie la dernière version de Claude Desktop dans le dépôt apt d'Anthropic
# et met à jour pinned.json avec le hash SRI du .deb amd64, calculé via
# `nix store prefetch-file` — même technique qu'artcraft/update.sh, pour que
# le hash corresponde à l'artefact réellement empaqueté.
# Lancé par update.sh (commande `update`, ou `rebuild -u`).
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
dir="$flake/modules/user/apps/claude-desktop"
pinned_file="$dir/pinned.json"
repo="https://downloads.claude.ai/claude-desktop/apt/stable"

echo "🔎 Checking latest Claude Desktop release..."
# Index apt : une entrée par version publiée, on garde la plus récente.
# Index illisible ou vide -> échec explicite ici plutôt qu'une URL ..._amd64.deb
# sans version.
if ! version=$(curl -fsSL "$repo/dists/stable/main/binary-amd64/Packages" \
    | sed -n 's/^Version: //p' | sort -V | tail -n 1) || [ -z "$version" ]; then
    echo "⚠️ Error: Could not read latest Claude Desktop version" >&2
    exit 1
fi
echo "Latest version: $version"

if [ "$check" -eq 1 ]; then
    current=$(jq -r '.version // empty' "$pinned_file" 2>/dev/null || true)
    jq -nc --arg name "Claude Desktop" --arg current "$current" --arg latest "$version" \
        --arg url "" '{$name, $current, $latest, $url}' >&3
    exit 0
fi

if [ -f "$pinned_file" ]; then
    current_version=$(jq -r '.version // empty' "$pinned_file" 2>/dev/null || echo "")
    if [ "$current_version" = "$version" ]; then
        echo "✓ Claude Desktop is already up to date ($version)"
        exit 0
    fi
fi

deb_url="$repo/pool/main/c/claude-desktop/claude-desktop_${version}_amd64.deb"
echo "🔎 Fetching + hashing .deb for $version..."
if ! prefetch=$(nix store prefetch-file --json "$deb_url" 2>/dev/null) \
    || ! sha256=$(printf '%s' "$prefetch" | jq -er '.hash' 2>/dev/null); then
    echo "⚠️ Error: Could not retrieve sha256 for claude-desktop .deb" >&2
    exit 1
fi

cat <<EOT > "$pinned_file"
{
  "version": "$version",
  "sha256": "$sha256"
}
EOT

echo "⬆️ Updated Claude Desktop to version $version"
