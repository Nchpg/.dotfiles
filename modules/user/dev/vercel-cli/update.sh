#!/usr/bin/env bash
# Vérifie la dernière version publiée de Vercel CLI sur le registre npm (celui
# qu'utilise réellement `npx`, cf. default.nix) et met à jour pinned.json avec
# le hash SRI du tarball, calculé via `nix store prefetch-file` — même
# technique que kimi-code/update.sh, pour que le hash corresponde à
# l'artefact effectivement exécuté.
# Intégré au processus `--update` de rebuild.sh.
set -euo pipefail

flake="${MY_FLAKE:-$HOME/.dotfiles}"
dir="$flake/modules/user/dev/vercel-cli"
pinned_file="$dir/pinned.json"

echo "🔎 Checking latest Vercel CLI version (npm registry)..."
version=$(curl -fsSL "https://registry.npmjs.org/vercel" | jq -r '."dist-tags".latest')
echo "Latest version: $version"

if [ -f "$pinned_file" ]; then
    current_version=$(jq -r '.version // empty' "$pinned_file" 2>/dev/null || echo "")
    if [ "$current_version" = "$version" ]; then
        echo "✓ Vercel CLI is already up to date ($version)"
        exit 0
    fi
fi

tarball_url="https://registry.npmjs.org/vercel/-/vercel-${version}.tgz"
echo "🔎 Fetching + hashing tarball for $version..."
# --json donne directement le hash au format SRI (sha256-...), attendu tel
# quel par fetchurl dans default.nix : pas de conversion à faire.
if ! prefetch=$(nix store prefetch-file --json "$tarball_url" 2>/dev/null) \
    || ! sha256=$(printf '%s' "$prefetch" | jq -er '.hash' 2>/dev/null); then
    echo "⚠️ Error: Could not retrieve sha256 for vercel tarball" >&2
    exit 1
fi

cat <<EOF > "$pinned_file"
{
  "version": "$version",
  "sha256": "$sha256"
}
EOF


echo "⬆️ Updated Vercel CLI to version $version"
