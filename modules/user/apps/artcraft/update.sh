#!/usr/bin/env bash
# Vérifie la dernière release GitHub d'ArtCraft Launcher (storytold/craft-launcher)
# et met à jour pinned.json avec le hash SRI de l'AppImage x86_64, calculé via
# `nix store prefetch-file` — même technique que mammouth-code/update.sh, pour
# que le hash corresponde à l'artefact réellement empaqueté.
# Seul le launcher est épinglé ici : les apps de la suite, il les installe et
# les met à jour lui-même dans ~/Applications (cf. default.nix).
# Intégré au processus `--update` de rebuild.sh.
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
dir="$flake/modules/user/apps/artcraft"
pinned_file="$dir/pinned.json"

echo "🔎 Checking latest ArtCraft Launcher release..."
# Jeton facultatif (GITHUB_TOKEN, exporté par la CI) : sans lui l'API GitHub
# plafonne à 60 requêtes/h par IP, vite atteint sur un runner partagé.
auth=()
[ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
# jq -e + // empty : réponse inattendue (rate limit, pas de release) -> échec
# explicite ici plutôt qu'une version "null" et une URL ...vnull...
if ! version=$(curl -fsSL "${auth[@]}" "https://api.github.com/repos/storytold/craft-launcher/releases/latest" \
    | jq -er '.tag_name // empty | ltrimstr("v")') || [ -z "$version" ]; then
    echo "⚠️ Error: Could not read latest ArtCraft Launcher version" >&2
    exit 1
fi
echo "Latest version: $version"

if [ "$check" -eq 1 ]; then
    current=$(jq -r '.version // empty' "$pinned_file" 2>/dev/null || true)
    jq -nc --arg name "ArtCraft Launcher" --arg current "$current" --arg latest "$version" \
        --arg url "https://github.com/storytold/craft-launcher/releases/tag/v$version" '{$name, $current, $latest, $url}' >&3
    exit 0
fi

if [ -f "$pinned_file" ]; then
    current_version=$(jq -r '.version // empty' "$pinned_file" 2>/dev/null || echo "")
    if [ "$current_version" = "$version" ]; then
        echo "✓ ArtCraft Launcher is already up to date ($version)"
        exit 0
    fi
fi

appimage_url="https://github.com/storytold/craft-launcher/releases/download/v${version}/artcraft-launcher-${version}-linux-x86_64.AppImage"
echo "🔎 Fetching + hashing AppImage for $version..."
if ! prefetch=$(nix store prefetch-file --json "$appimage_url" 2>/dev/null) \
    || ! sha256=$(printf '%s' "$prefetch" | jq -er '.hash' 2>/dev/null); then
    echo "⚠️ Error: Could not retrieve sha256 for artcraft-launcher AppImage" >&2
    exit 1
fi

cat <<EOF > "$pinned_file"
{
  "version": "$version",
  "sha256": "$sha256"
}
EOF


echo "⬆️ Updated ArtCraft Launcher to version $version"
