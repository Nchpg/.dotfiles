# shellcheck shell=bash
# Lecture d'un registre OCI (digest d'un tag, port exposé, commit source), sans démon ni skopeo.
# Partagé par modules/system/server/apps/update.sh et la surveillance de think (app-images/watch.nix).
# L'appelant fournit `REG_WORK`, un répertoire privé (umask 077) ; GHCR_TOKEN est facultatif.
# Dépendances : curl, jq, sed, tr.

# Index multi-architecture d'abord : c'est le digest que tire podman pour un tag.
reg_accept=(
    -H "Accept: application/vnd.oci.image.index.v1+json"
    -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json"
    -H "Accept: application/vnd.oci.image.manifest.v1+json"
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json"
)

# `registre/chemin:tag` -> reg_host, reg_repo, reg_tag (Docker Hub implicite pour un nom sans domaine).
reg_split() {
    local ref="$1" first rest
    first="${ref%%/*}"
    if [[ "$ref" == */* && ( "$first" == *.* || "$first" == *:* || "$first" == localhost ) ]]; then
        reg_host="$first"
        rest="${ref#*/}"
    else
        reg_host="registry-1.docker.io"
        rest="$ref"
        [[ "$rest" == */* ]] || rest="library/$rest"
    fi
    [ "$reg_host" = docker.io ] && reg_host="registry-1.docker.io"
    if [[ "${rest##*/}" == *:* ]]; then
        reg_tag="${rest##*:}"
        reg_repo="${rest%:*}"
    else
        reg_tag="latest"
        reg_repo="$rest"
    fi
    reg_base="https://$reg_host/v2/$reg_repo"
}

# Prépare `reg_auth` pour reg_base : jeton porteur anonyme, ou par GHCR_TOKEN sur ghcr.io.
# Secrets passés à curl par fichier : un argument est lisible par tous dans /proc.
reg_login() {
    local challenge realm service creds=() token
    reg_auth=()
    challenge=$(curl -sS --max-time 15 -o /dev/null -D - -I "${reg_accept[@]}" "$reg_base/manifests/$reg_tag" \
        | tr -d '\r' | sed -n 's/^[Ww][Ww][Ww]-[Aa]uthenticate: *[Bb]earer *//p')
    [ -n "$challenge" ] || return 0
    realm=$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<<"$challenge")
    service=$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<<"$challenge")
    if [ "$reg_host" = ghcr.io ] && [ -n "${GHCR_TOKEN:-}" ]; then
        printf 'user = "token:%s"\n' "$GHCR_TOKEN" >"$REG_WORK/creds"
        creds=(--config "$REG_WORK/creds")
    fi
    token=$(curl -fsS --max-time 15 "${creds[@]}" --get \
        --data-urlencode "service=$service" --data-urlencode "scope=repository:$reg_repo:pull" "$realm" \
        | jq -er '.token // .access_token') || return 1
    printf 'header = "Authorization: Bearer %s"\n' "$token" >"$REG_WORK/auth"
    reg_auth=(--config "$REG_WORK/auth")
}

# Digest du tag, par une seule requête HEAD (ne compte pas dans les quotas de tirage).
reg_digest() {
    reg_split "$1"
    reg_login || return 1
    curl -fsS --max-time 15 -o /dev/null -D - -I "${reg_accept[@]}" "${reg_auth[@]}" "$reg_base/manifests/$reg_tag" \
        | tr -d '\r' | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: *\(sha256:[0-9a-f]\{64\}\)$/\1/p' | grep .
}

# `{digest, port, revision, source}` du tag, en JSON. port `null` si l'image n'expose pas
# exactement un port TCP ; revision et source viennent des labels OCI posés par app-image.yml.
# Redirections suivies sans l'en-tête d'autorisation (curl ne le renvoie pas à un autre hôte).
reg_inspect() {
    local digest manifest platform config
    reg_split "$1"
    reg_login || return 1
    curl -fsS --max-time 15 "${reg_accept[@]}" "${reg_auth[@]}" -D "$REG_WORK/headers" -o "$REG_WORK/manifest" \
        "$reg_base/manifests/$reg_tag" || return 1
    digest=$(tr -d '\r' <"$REG_WORK/headers" \
        | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: *\(sha256:[0-9a-f]\{64\}\)$/\1/p')
    [ -n "$digest" ] || return 1

    manifest="$REG_WORK/manifest"
    platform=$(jq -r '[.manifests[]? | select(.platform.os == "linux" and .platform.architecture == "amd64")][0].digest // empty' "$manifest")
    if [ -n "$platform" ]; then
        curl -fsS --max-time 15 "${reg_accept[@]}" "${reg_auth[@]}" -o "$REG_WORK/platform" "$reg_base/manifests/$platform" \
            || return 1
        manifest="$REG_WORK/platform"
    fi
    config=$(jq -er '.config.digest' "$manifest") || return 1
    curl -fsSL --max-time 30 "${reg_auth[@]}" "$reg_base/blobs/$config" | jq -c --arg digest "$digest" '{
        $digest,
        port: ([.config.ExposedPorts // {} | keys[] | select(endswith("/tcp")) | rtrimstr("/tcp") | tonumber]
               | if length == 1 then .[0] else null end),
        revision: (.config.Labels["org.opencontainers.image.revision"] // null),
        source: (.config.Labels["org.opencontainers.image.source"] // null)
    }'
}
