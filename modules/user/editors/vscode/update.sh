#!/usr/bin/env bash
# L'API Marketplace n'est pas officielle : un échec est toujours non bloquant.
set -euo pipefail
# shellcheck source=scripts/lib/update-module.sh
. "${MY_FLAKE:-$HOME/.dotfiles}/scripts/lib/update-module.sh"
um_init "$@"

file="$UM_DIR/extensions.json"
if [ ! -f "$file" ]; then
    echo "Fichier introuvable : $file" >&2
    exit 1
fi

# filterType 7 = recherche exacte "publisher.name" ; flags 103 = inclut les versions.
# `|| return 1` : sinon set -e interrompt tout avant la garde de l'appelant.
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

if [ "$UM_CHECK" -eq 1 ]; then
    changes="[]"
    failed=0
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
    if ! prefetch=$(nix store prefetch-file --json "$url" 2>/dev/null) \
        || ! hash=$(printf '%s' "$prefetch" | jq -er '.hash' 2>/dev/null); then
        echo "⚠️  $key : téléchargement du vsix échoué ($latest), ignoré." >&2
        note_skip "$key" "téléchargement du vsix $latest échoué"
        continue
    fi
    current_hash=$(jq -r ".\"$key\".hash" "$file")

    # Téléchargement même à version identique : le Marketplace republie parfois des octets différents.
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

if [ "$skipped" -gt 0 ]; then
    echo "::warning::$skipped extension(s) ignorée(s) : API Marketplace ou téléchargement en échec."
fi

if [ -n "${VSCODE_SKIPPED_FILE:-}" ]; then
    printf '%s\n' "$skipped_json" > "$VSCODE_SKIPPED_FILE"
fi
