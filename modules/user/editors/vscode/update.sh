#!/usr/bin/env bash
# Vérifie la dernière version publiée de chaque extension marketplace de
# extensions.json (API du VS Code Marketplace), et bump version + hash (via
# `nix store prefetch-file`) pour celles qui ont bougé. Protocole (--check,
# --only KEY...) : cf. scripts/lib/update-module.sh.
#
# Ramassé automatiquement par la commande `update` et par la CI hebdo (cf.
# `find modules -name update.sh` dans scripts/update.sh / update.yml) : ce nom
# est une convention, pas un hasard. L'API Marketplace n'étant ni officielle
# ni garantie stable, un échec ici est TOUJOURS non bloquant (cf. note_skip
# plus bas) — le coût accepté est une mise à jour parfois plus lente/flaky.
#
# `arch` (facultatif, ex. "linux-x64") : VSIX propre à une plateforme, la
# même clé que lit vscode-utils de nixpkgs (?targetPlatform= dans l'URL). La
# version et le hash suivent alors cette plateforme-là.
set -euo pipefail
# shellcheck source=scripts/lib/update-module.sh
. "${MY_FLAKE:-$HOME/.dotfiles}/scripts/lib/update-module.sh"
um_init "$@"

file="$UM_DIR/extensions.json"
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
    local publisher="$1" name="$2" arch="$3" response body
    body=$(jq -n --arg v "${publisher}.${name}" \
        '{filters: [{criteria: [{filterType: 7, value: $v}]}], flags: 103}')
    response=$(curl -sf -X POST "https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json;api-version=3.0-preview.1" \
        -d "$body") || return 1
    printf '%s' "$response" | jq -r --arg a "$arch" \
        '[.results[0].extensions[0].versions[] | select($a == "" or .targetPlatform == $a)][0].version // empty' \
        2>/dev/null || return 1
}

# --check : versions seulement, sans télécharger les vsix. La détection d'un
# contenu republié à version égale (cf. plus bas) exige le téléchargement :
# elle n'a lieu qu'en mise à jour réelle.
if [ "$UM_CHECK" -eq 1 ]; then
    changes="[]"
    failed=0
    # Requêtes en parallèle (une par extension) : en série, ~6 s.
    results=$(mktemp -d)
    trap 'rm -rf "$results"' EXIT
    for key in $(jq -r 'keys[]' "$file"); do
        publisher=$(jq -r ".\"$key\".publisher" "$file")
        name=$(jq -r ".\"$key\".name" "$file")
        arch=$(jq -r ".\"$key\".arch // empty" "$file")
        (query_latest_version "$publisher" "$name" "$arch" >"$results/$key" 2>/dev/null || true) &
    done
    wait
    for key in $(jq -r 'keys[]' "$file"); do
        name=$(jq -r ".\"$key\".name" "$file")
        current=$(jq -r ".\"$key\".version" "$file")
        latest=$(cat "$results/$key")
        if [ -z "$latest" ]; then
            failed=$((failed + 1))
            continue
        fi
        if [ "$latest" != "$current" ]; then
            changes=$(jq -c --arg k "$key" --arg n "$name" --arg c "$current" --arg l "$latest" \
                --arg u "https://marketplace.visualstudio.com/items?itemName=$key" \
                '. + [{key: $k, name: "VS Code · \($n)", current: $c, latest: $l, url: $u}]' <<<"$changes")
        fi
    done
    total=$(jq -r 'keys | length' "$file")
    note=""
    [ "$failed" -gt 0 ] && note="$failed extension(s) non vérifiée(s) (API Marketplace)"
    jq -nc --argjson changes "$changes" --argjson total "$total" --arg note "$note" '{
        name: "VS Code (extensions)",
        current: "\($total) extensions",
        latest: (if ($changes | length) == 0 then "\($total) extensions"
                 else "\($changes | length) à mettre à jour" end),
        available: (($changes | length) > 0),
        items: $changes,
        $note
    }' >&3
    exit 0
fi

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
    if [ ${#UM_ONLY[@]} -gt 0 ] && ! printf '%s\n' "${UM_ONLY[@]}" | grep -qxF "$key"; then
        continue
    fi
    publisher=$(jq -r ".\"$key\".publisher" "$file")
    name=$(jq -r ".\"$key\".name" "$file")
    current=$(jq -r ".\"$key\".version" "$file")
    arch=$(jq -r ".\"$key\".arch // empty" "$file")

    latest=$(query_latest_version "$publisher" "$name" "$arch") || latest=""
    if [ -z "$latest" ]; then
        echo "⚠️  $key : impossible de récupérer la dernière version (API Marketplace), ignoré." >&2
        note_skip "$key" "API Marketplace injoignable ou réponse invalide"
        continue
    fi

    url="https://marketplace.visualstudio.com/_apis/public/gallery/publishers/${publisher}/vsextensions/${name}/${latest}/vspackage${arch:+?targetPlatform=$arch}"
    # --json donne directement le hash au format SRI (sha256-...), attendu tel
    # quel par extensionsFromVscodeMarketplace : pas de conversion à faire.
    if ! prefetch=$(nix store prefetch-file --json "$url" 2>/dev/null) \
        || ! hash=$(printf '%s' "$prefetch" | jq -er '.hash' 2>/dev/null); then
        echo "⚠️  $key : téléchargement du vsix échoué ($latest), ignoré." >&2
        note_skip "$key" "téléchargement du vsix $latest échoué"
        continue
    fi
    current_hash=$(jq -r ".\"$key\".hash" "$file")

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

    # shellcheck disable=SC2016 # $k, $v, $h : variables jq
    um_replace "$file" jq --arg k "$key" --arg v "$latest" --arg h "$hash" \
        '.[$k].version = $v | .[$k].hash = $h' "$file"
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
