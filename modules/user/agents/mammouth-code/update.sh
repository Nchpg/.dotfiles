#!/usr/bin/env bash
# Vérifie la dernière release GitHub de Mammouth Code (mammouth-ai/code) et
# met à jour pinned.json avec le hash SRI du tarball linux-x64, calculé via
# `nix store prefetch-file` — même technique que vscode/update.sh et
# kimi-code/update.sh, pour que le hash corresponde à l'artefact réellement
# installé (binaire précompilé, pas de paquet npm ici).
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
dir="$flake/modules/user/agents/mammouth-code"
pinned_file="$dir/pinned.json"

echo "🔎 Checking latest Mammouth Code release..."
# Jeton facultatif (GITHUB_TOKEN, exporté par update.sh depuis gh ou par la
# CI) : sans lui l'API GitHub plafonne à 60 requêtes/h par IP, et le 403 qui
# s'ensuit faisait échouer ce module.
auth=()
[ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
if ! release=$(curl -fsSL "${auth[@]}" "https://api.github.com/repos/mammouth-ai/code/releases/latest") \
    || ! version=$(printf '%s' "$release" | jq -er '.tag_name | ltrimstr("v")'); then
    echo "⚠️ Error: Could not read latest Mammouth Code release" >&2
    exit 1
fi
echo "Latest version: $version"

if [ "$check" -eq 1 ]; then
    current=$(jq -r '.version // empty' "$pinned_file" 2>/dev/null || true)
    jq -nc --arg name "Mammouth Code" --arg current "$current" --arg latest "$version" \
        --arg url "https://github.com/mammouth-ai/code/releases/tag/v$version" '{$name, $current, $latest, $url}' >&3
    exit 0
fi

if [ -f "$pinned_file" ]; then
    current_version=$(jq -r '.version // empty' "$pinned_file" 2>/dev/null || echo "")
    if [ "$current_version" = "$version" ]; then
        echo "✓ Mammouth Code is already up to date ($version)"
        exit 0
    fi
fi

# linux-x64 (AVX2) uniquement : seule plateforme utilisée ici, comme
# kimi-code/update.sh qui ne gère que linux-x64.
tarball_url="https://github.com/mammouth-ai/code/releases/download/v${version}/mammouth-linux-x64.tar.gz"
echo "🔎 Fetching + hashing tarball for $version..."
if ! prefetch=$(nix store prefetch-file --json "$tarball_url" 2>/dev/null) \
    || ! sha256=$(printf '%s' "$prefetch" | jq -er '.hash' 2>/dev/null); then
    echo "⚠️ Error: Could not retrieve sha256 for mammouth-code tarball" >&2
    exit 1
fi

cat <<EOF > "$pinned_file"
{
  "version": "$version",
  "sha256": "$sha256"
}
EOF


echo "⬆️ Updated Mammouth Code to version $version"
