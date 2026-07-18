#!/usr/bin/env bash
# Vérifie la dernière version publiée de chaque extension marketplace de
# extensions.json (API du VS Code Marketplace), et bump version + sha256 (via
# `nix store prefetch-file`) pour celles qui ont bougé.
#
# Commande manuelle, comme `rebuild -u` pour l'input claude-code : jamais en
# CI ni au rebuild, l'API Marketplace n'étant ni officielle ni garantie
# stable, et une extension cassée par une MAJ non testée serait pire que
# l'inertie actuelle. Lancer, relire le diff, puis committer + rebuild.
set -euo pipefail

flake="${MY_FLAKE:-$HOME/.dotfiles}"
file="$flake/modules/user/vscode/extensions.json"

if [ ! -f "$file" ]; then
    echo "Fichier introuvable : $file" >&2
    exit 1
fi

# filterType 7 = recherche exacte par "publisher.name" ; flags 103 = inclut la
# liste des versions (la plus récente en premier).
query_latest_version() {
    local publisher="$1" name="$2"
    curl -s -X POST "https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json;api-version=3.0-preview.1" \
        -d "{\"filters\":[{\"criteria\":[{\"filterType\":7,\"value\":\"${publisher}.${name}\"}]}],\"flags\":103}" \
        | jq -r '.results[0].extensions[0].versions[0].version // empty'
}

updated=0
for key in $(jq -r 'keys[]' "$file"); do
    publisher=$(jq -r ".\"$key\".publisher" "$file")
    name=$(jq -r ".\"$key\".name" "$file")
    current=$(jq -r ".\"$key\".version" "$file")

    latest=$(query_latest_version "$publisher" "$name")
    if [ -z "$latest" ]; then
        echo "⚠️  $key : impossible de récupérer la dernière version (API Marketplace), ignoré." >&2
        continue
    fi

    url="https://marketplace.visualstudio.com/_apis/public/gallery/publishers/${publisher}/vsextensions/${name}/${latest}/vspackage"
    # --json donne directement le hash au format SRI (sha256-...), attendu tel
    # quel par extensionsFromVscodeMarketplace : pas de conversion à faire.
    hash=$(nix store prefetch-file --json "$url" | jq -r '.hash')
    current_hash=$(jq -r ".\"$key\".sha256" "$file")

    # On télécharge TOUJOURS, même à version identique, et on compare le
    # contenu : le Marketplace republie parfois une même version avec des
    # octets différents (resignature/recompression). Ni un rebuild local ni la
    # CI ne peuvent voir cette dérive — dès que la sortie est dans le store,
    # Nix ne redescend plus jusqu'au téléchargement, donc ne revérifie plus le
    # hash de la FOD. Ce script est le seul maillon qui fetch inconditionnellement.
    if [ "$latest" = "$current" ] && [ "$hash" = "$current_hash" ]; then
        echo "✓ $key : à jour ($current)"
        continue
    fi

    if [ "$latest" = "$current" ]; then
        echo "🔁 $key : $current inchangée, contenu republié — bump du hash"
    else
        echo "⬆️  $key : $current -> $latest"
    fi

    tmp=$(mktemp)
    jq --arg k "$key" --arg v "$latest" --arg h "$hash" \
        '.[$k].version = $v | .[$k].sha256 = $h' "$file" > "$tmp"
    mv "$tmp" "$file"
    updated=$((updated + 1))
done

if [ "$updated" -eq 0 ]; then
    echo "Aucune extension à mettre à jour."
else
    echo "$updated extension(s) mise(s) à jour dans $file — vérifie le diff, puis rebuild."
fi
