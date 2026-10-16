#!/usr/bin/env bash
# Suit le tag de chaque image de profiles/server/apps.lock.json et y reporte son digest et son port exposé.
# Filet de sécurité : d'ordinaire, la CI de l'app déclenche apps-bump.yml (cf. docs/apps.md).
# Image privée : GHCR_TOKEN (portée read:packages), sinon elle est signalée et laissée telle quelle.
set -euo pipefail
# shellcheck source=scripts/lib/update-module.sh
. "${MY_FLAKE:-$HOME/.dotfiles}/scripts/lib/update-module.sh"
um_init "$@"

lock="$UM_FLAKE/profiles/server/apps.lock.json"
[ -f "$lock" ] || um_die "lock introuvable : $lock"

# Index multi-architecture d'abord : c'est le digest que tire podman pour un tag.
accept=(
    -H "Accept: application/vnd.oci.image.index.v1+json"
    -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json"
    -H "Accept: application/vnd.oci.image.manifest.v1+json"
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json"
)

# `registre/chemin:tag` -> registre, chemin, tag (Docker Hub implicite pour un nom sans domaine).
split_ref() {
    local ref="$1" first rest
    first="${ref%%/*}"
    if [[ "$ref" == */* && ( "$first" == *.* || "$first" == *:* || "$first" == localhost ) ]]; then
        host="$first"
        rest="${ref#*/}"
    else
        host="registry-1.docker.io"
        rest="$ref"
        [[ "$rest" == */* ]] || rest="library/$rest"
    fi
    [ "$host" = docker.io ] && host="registry-1.docker.io"
    if [[ "${rest##*/}" == *:* ]]; then
        tag="${rest##*:}"
        repo="${rest%:*}"
    else
        tag="latest"
        repo="$rest"
    fi
}

# Secrets passés à curl par fichier : un argument est lisible par tous dans /proc.
umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curlrc="$work/curlrc"

# Jeton porteur anonyme, ou authentifié par GHCR_TOKEN sur ghcr.io.
bearer() {
    local url="$1" challenge realm service creds=()
    challenge=$(curl -sS --max-time 15 -o /dev/null -D - -I "${accept[@]}" "$url" \
        | tr -d '\r' | sed -n 's/^[Ww][Ww][Ww]-[Aa]uthenticate: *[Bb]earer *//p')
    [ -n "$challenge" ] || return 0
    realm=$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<<"$challenge")
    service=$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<<"$challenge")
    if [ "$host" = ghcr.io ] && [ -n "${GHCR_TOKEN:-}" ]; then
        printf 'user = "token:%s"\n' "$GHCR_TOKEN" >"$curlrc"
        creds=(--config "$curlrc")
    fi
    curl -fsS --max-time 15 "${creds[@]}" --get \
        --data-urlencode "service=$service" --data-urlencode "scope=repository:$repo:pull" "$realm" \
        | jq -er '.token // .access_token'
}

# `<digest> <port>` du tag ; port `null` si l'image n'expose pas exactement un port TCP.
# Redirections suivies sans l'en-tête d'autorisation (curl ne le renvoie pas à un autre hôte).
inspect() {
    local host repo tag base token auth=() digest manifest platform config port
    split_ref "$1"
    base="https://$host/v2/$repo"
    token=$(bearer "$base/manifests/$tag") || return 1
    if [ -n "$token" ]; then
        printf 'header = "Authorization: Bearer %s"\n' "$token" >"$curlrc"
        auth=(--config "$curlrc")
    fi
    curl -fsS --max-time 15 "${accept[@]}" "${auth[@]}" -D "$work/headers" -o "$work/manifest" "$base/manifests/$tag" \
        || return 1
    digest=$(tr -d '\r' <"$work/headers" \
        | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: *\(sha256:[0-9a-f]\{64\}\)$/\1/p')
    [ -n "$digest" ] || return 1

    manifest="$work/manifest"
    platform=$(jq -r '[.manifests[]? | select(.platform.os == "linux" and .platform.architecture == "amd64")][0].digest // empty' "$manifest")
    if [ -n "$platform" ]; then
        curl -fsS --max-time 15 "${accept[@]}" "${auth[@]}" -o "$work/platform" "$base/manifests/$platform" || return 1
        manifest="$work/platform"
    fi
    config=$(jq -er '.config.digest' "$manifest") || return 1
    port=$(curl -fsSL --max-time 30 "${auth[@]}" "$base/blobs/$config" \
        | jq -r '[.config.ExposedPorts // {} | keys[] | select(endswith("/tcp")) | rtrimstr("/tcp") | tonumber]
                 | if length == 1 then .[0] else null end') || return 1
    printf '%s %s\n' "$digest" "$port"
}

short() { if [ -n "$1" ]; then printf '%s\n' "${1:7:12}"; else echo absente; fi; }

# Le lock, plus les images de la config qui n'y sont pas encore : une nouvelle app y entre ici.
if wanted=$(nix eval --json "$UM_FLAKE#nixosConfigurations.server-think.config.systemSettings.appImages.wanted" 2>/dev/null); then
    mapfile -t refs < <({ jq -r 'keys[]' "$lock"; jq -r '.[]' <<<"$wanted"; } | sort -u)
else
    echo "⚠️ évaluation de server-think impossible : seules les images déjà dans le lock sont suivies" >&2
    mapfile -t refs < <(jq -r 'keys[]' "$lock")
fi

declare -A latest exposed
failed=()
for ref in "${refs[@]}"; do
    if [ ${#UM_ONLY[@]} -gt 0 ] && ! printf '%s\n' "${UM_ONLY[@]}" | grep -qxF "$ref"; then
        continue
    fi
    if r=$(inspect "$ref" 2>/dev/null); then
        latest[$ref]="${r% *}"
        exposed[$ref]="${r#* }"
    else
        failed+=("$ref")
    fi
done
note=""
[ ${#failed[@]} -gt 0 ] && note="non vérifiée(s) (privée sans GHCR_TOKEN, ou tag absent) : ${failed[*]}"

if [ "$UM_CHECK" -eq 1 ]; then
    changes="[]"
    for ref in "${!latest[@]}"; do
        current=$(jq -r --arg r "$ref" '.[$r].digest // ""' "$lock")
        port=$(jq -r --arg r "$ref" '.[$r].port' "$lock")
        [ "${latest[$ref]}" = "$current" ] && [ "${exposed[$ref]}" = "$port" ] && continue
        changes=$(jq -c --arg k "$ref" --arg c "$(short "$current")" --arg l "$(short "${latest[$ref]}")" \
            '. + [{key: $k, name: "Image · \($k)", current: $c, latest: $l, url: ""}]' <<<"$changes")
    done
    jq -nc --argjson changes "$changes" --argjson total "${#refs[@]}" --arg note "$note" '{
        name: "Images des apps",
        current: "\($total) images",
        latest: (if ($changes | length) == 0 then "\($total) images"
                 else "\($changes | length) à mettre à jour" end),
        available: (($changes | length) > 0),
        items: ($changes | sort_by(.key)),
        $note
    }' >&3
    exit 0
fi

[ -n "$note" ] && echo "⚠️ $note" >&2

updated=0
for ref in "${!latest[@]}"; do
    current=$(jq -r --arg r "$ref" '.[$r].digest // ""' "$lock")
    port=$(jq -r --arg r "$ref" '.[$r].port' "$lock")
    if [ "${latest[$ref]}" = "$current" ] && [ "${exposed[$ref]}" = "$port" ]; then
        echo "✓ $ref est à jour ($(short "$current"))"
        continue
    fi
    # La révision source n'est connue que du chemin CI (apps-bump.yml).
    # shellcheck disable=SC2016 # $r, $d et $p sont du jq
    um_replace "$lock" jq --sort-keys --indent 2 --arg r "$ref" --arg d "${latest[$ref]}" \
        --argjson p "${exposed[$ref]}" '.[$r] = {digest: $d, port: $p, revision: null}' "$lock"
    echo "⬆️ $ref : $(short "$current") → $(short "${latest[$ref]}"), port ${exposed[$ref]}"
    updated=$((updated + 1))
done

echo "$updated image(s) mise(s) à jour."
