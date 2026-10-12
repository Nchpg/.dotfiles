#!/usr/bin/env bash
# Vérifie la dernière version publiée de Kimi Code sur le registre npm (celui
# qu'utilise réellement `npx`, cf. default.nix) et met à jour pinned.json avec
# le hash SRI du tarball, calculé via `nix store prefetch-file` — même
# technique que vscode/update.sh, pour que le hash corresponde à l'artefact
# effectivement exécuté (et pas à un binaire natif jamais utilisé).
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
dir="$flake/modules/user/agents/kimi-code"
pinned_file="$dir/pinned.json"

echo "🔎 Checking latest Kimi Code version (npm registry)..."
version=$(curl -fsSL "https://registry.npmjs.org/@moonshot-ai/kimi-code" | jq -r '."dist-tags".latest')
echo "Latest version: $version"

if [ "$check" -eq 1 ]; then
    current=$(jq -r '.version // empty' "$pinned_file" 2>/dev/null || true)
    jq -nc --arg name "Kimi Code" --arg current "$current" --arg latest "$version" \
        --arg url "https://www.npmjs.com/package/@moonshot-ai/kimi-code/v/$version" '{$name, $current, $latest, $url}' >&3
    exit 0
fi

if [ -f "$pinned_file" ]; then
    current_version=$(jq -r '.version // empty' "$pinned_file" 2>/dev/null || echo "")
    if [ "$current_version" = "$version" ]; then
        echo "✓ Kimi Code is already up to date ($version)"
        exit 0
    fi
fi

tarball_url="https://registry.npmjs.org/@moonshot-ai/kimi-code/-/kimi-code-${version}.tgz"
echo "🔎 Fetching + hashing tarball for $version..."
# --json donne directement le hash au format SRI (sha256-...), attendu tel
# quel par fetchurl dans default.nix : pas de conversion à faire.
if ! prefetch=$(nix store prefetch-file --json "$tarball_url" 2>/dev/null) \
    || ! sha256=$(printf '%s' "$prefetch" | jq -er '.hash' 2>/dev/null); then
    echo "⚠️ Error: Could not retrieve sha256 for kimi-code tarball" >&2
    exit 1
fi

cat <<EOF > "$pinned_file"
{
  "version": "$version",
  "sha256": "$sha256"
}
EOF


echo "⬆️ Updated Kimi Code to version $version"
