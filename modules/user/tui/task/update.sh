#!/usr/bin/env bash
# Vérifie la dernière version de tasks-tui-app sur PyPI et met à jour
# pinned.json avec le hash SRI du sdist. Pas de téléchargement : PyPI publie
# le sha256 du fichier, converti tel quel au format attendu par fetchPypi.
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
dir="$flake/modules/user/tui/task"
pinned_file="$dir/pinned.json"

echo "🔎 Checking latest tasks-tui-app version (PyPI)..."
if ! version=$(curl -fsSL "https://pypi.org/pypi/tasks-tui-app/json" | jq -er '.info.version // empty') \
    || [ -z "$version" ]; then
    echo "⚠️ Error: Could not read latest tasks-tui-app version" >&2
    exit 1
fi
echo "Latest version: $version"

if [ "$check" -eq 1 ]; then
    current=$(jq -r '.version // empty' "$pinned_file" 2>/dev/null || true)
    jq -nc --arg name "tasks-tui" --arg current "$current" --arg latest "$version" \
        --arg url "https://pypi.org/project/tasks-tui-app/$version/" '{$name, $current, $latest, $url}' >&3
    exit 0
fi

if [ -f "$pinned_file" ]; then
    current_version=$(jq -r '.version // empty' "$pinned_file" 2>/dev/null || echo "")
    if [ "$current_version" = "$version" ]; then
        echo "✓ tasks-tui-app is already up to date ($version)"
        exit 0
    fi
fi

# Le sdist, celui que fetchPypi télécharge (pas la wheel).
echo "🔎 Reading sdist hash for $version..."
if ! hex=$(curl -fsSL "https://pypi.org/pypi/tasks-tui-app/${version}/json" \
    | jq -er '[.urls[] | select(.packagetype == "sdist")][0].digests.sha256') \
    || ! hash=$(nix hash convert --hash-algo sha256 --to sri "$hex"); then
    echo "⚠️ Error: Could not retrieve sdist hash for tasks-tui-app" >&2
    exit 1
fi

cat <<EOT > "$pinned_file"
{
  "version": "$version",
  "hash": "$hash"
}
EOT

echo "⬆️ Updated tasks-tui-app to version $version"
