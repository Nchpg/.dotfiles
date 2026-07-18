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
#
# Toute défaillance réseau est LOCALE à une extension : on la signale et on
# passe à la suivante, jamais d'abandon global. L'API Marketplace n'est ni
# officielle ni fiable (throttling, pages d'erreur HTML), et une extension
# capricieuse ne doit pas faire perdre le `nix flake update` déjà effectué ni
# empêcher la PR hebdomadaire d'être créée.
#
# Les `|| return 1` sont indispensables : sous `set -euo pipefail`, un `curl |
# jq` qui échoue interrompt tout le script AVANT que l'appelant puisse tester
# le résultat — la garde « ignoré » plus bas n'était jamais atteinte.
query_latest_version() {
    local publisher="$1" name="$2" response
    response=$(curl -sf -X POST "https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json;api-version=3.0-preview.1" \
        -d "{\"filters\":[{\"criteria\":[{\"filterType\":7,\"value\":\"${publisher}.${name}\"}]}],\"flags\":103}") || return 1
    printf '%s' "$response" | jq -r '.results[0].extensions[0].versions[0].version // empty' 2>/dev/null || return 1
}

updated=0
skipped=0
# Extensions ignorées, accumulées en JSON pour être reprises dans le corps de
# la PR hebdomadaire (cf. VSCODE_SKIPPED_FILE en fin de script) : une
# extension non vérifiée doit être VISIBLE dans la PR, pas seulement dans le
# log du run que personne ne relit.
skipped_json="[]"
note_skip() {
    skipped=$((skipped + 1))
    skipped_json=$(jq --arg k "$1" --arg r "$2" '. + [{key: $k, reason: $r}]' <<<"$skipped_json")
}

for key in $(jq -r 'keys[]' "$file"); do
    publisher=$(jq -r ".\"$key\".publisher" "$file")
    name=$(jq -r ".\"$key\".name" "$file")
    current=$(jq -r ".\"$key\".version" "$file")

    latest=$(query_latest_version "$publisher" "$name") || latest=""
    if [ -z "$latest" ]; then
        echo "⚠️  $key : impossible de récupérer la dernière version (API Marketplace), ignoré." >&2
        note_skip "$key" "API Marketplace injoignable ou réponse invalide"
        continue
    fi

    url="https://marketplace.visualstudio.com/_apis/public/gallery/publishers/${publisher}/vsextensions/${name}/${latest}/vspackage"
    # --json donne directement le hash au format SRI (sha256-...), attendu tel
    # quel par extensionsFromVscodeMarketplace : pas de conversion à faire.
    if ! prefetch=$(nix store prefetch-file --json "$url" 2>/dev/null) \
        || ! hash=$(printf '%s' "$prefetch" | jq -er '.hash' 2>/dev/null); then
        echo "⚠️  $key : téléchargement du vsix échoué ($latest), ignoré." >&2
        note_skip "$key" "téléchargement du vsix $latest échoué"
        continue
    fi
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

# Les extensions ignorées ne font PAS échouer le run (une API tierce
# capricieuse ne doit pas bloquer la PR hebdomadaire), mais elles remontent en
# annotation GitHub pour rester visibles plutôt que noyées dans le log.
if [ "$skipped" -gt 0 ]; then
    echo "::warning::$skipped extension(s) ignorée(s) : API Marketplace ou téléchargement en échec."
fi

# Consommé par gather-update-facts.sh pour que la PR hebdomadaire liste ce qui
# n'a PAS pu être vérifié. Optionnel : hors CI la variable n'est pas définie et
# le script se comporte comme avant.
if [ -n "${VSCODE_SKIPPED_FILE:-}" ]; then
    printf '%s\n' "$skipped_json" > "$VSCODE_SKIPPED_FILE"
fi
