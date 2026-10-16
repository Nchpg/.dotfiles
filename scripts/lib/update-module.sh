# shellcheck shell=bash disable=SC2034 # UM_* : lues par les scripts qui sourcent ce fichier
# Protocole : `--check` émet {name, current, latest, url} en JSON sur fd 3 sans rien modifier
# (facultatifs : available, note, summary, items) ; `--only KEY...` ne traite que ces sous-éléments.

um_init() {
    UM_CHECK=0
    UM_ONLY=()
    case "${1:-}" in
        --check)
            UM_CHECK=1
            exec 3>&1 1>&2
            ;;
        --only)
            shift
            UM_ONLY=("$@")
            ;;
    esac

    UM_FLAKE="${MY_FLAKE:-$HOME/.dotfiles}"
    UM_DIR=$(cd "$(dirname "$0")" && pwd)
    UM_PINNED="$UM_DIR/pinned.json"

    UM_AUTH=()
    [ -n "${GITHUB_TOKEN:-}" ] && UM_AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN")
    return 0
}

um_die() {
    echo "⚠️ Error: $*" >&2
    exit 1
}

# Le jeton GitHub n'est envoyé qu'à GitHub, jamais à un registre tiers.
um_curl() {
    local url="$1"
    shift
    case "$url" in
        https://api.github.com/* | https://raw.githubusercontent.com/*)
            curl -fsSL "${UM_AUTH[@]}" "$@" "$url" ;;
        *)
            curl -fsSL "$@" "$url" ;;
    esac
}

um_pinned() {
    jq -r --arg k "$1" '.[$k] // empty' "$UM_PINNED" 2>/dev/null || true
}

# jq -e + // empty : échec explicite plutôt qu'une version "null".
um_latest_npm() {
    local v
    v=$(um_curl "https://registry.npmjs.org/$1" | jq -er '."dist-tags".latest // empty') && [ -n "$v" ] \
        || um_die "could not read latest version of $1 (npm registry)"
    printf '%s\n' "$v"
}

um_latest_pypi() {
    local v
    v=$(um_curl "https://pypi.org/pypi/$1/json" | jq -er '.info.version // empty') && [ -n "$v" ] \
        || um_die "could not read latest version of $1 (PyPI)"
    printf '%s\n' "$v"
}

um_latest_gh_release() {
    local v
    v=$(um_curl "https://api.github.com/repos/$1/releases/latest" | jq -er '.tag_name // empty | ltrimstr("v")') \
        && [ -n "$v" ] || um_die "could not read latest release of $1 (GitHub)"
    printf '%s\n' "$v"
}

# NOTE n'est émise que si elle est passée (même vide).
um_check() {
    if [ $# -ge 5 ]; then
        jq -nc --arg name "$1" --arg current "$2" --arg latest "$3" --arg url "${4:-}" --arg note "$5" \
            '{$name, $current, $latest, $url, $note}' >&3
    else
        jq -nc --arg name "$1" --arg current "$2" --arg latest "$3" --arg url "${4:-}" \
            '{$name, $current, $latest, $url}' >&3
    fi
    exit 0
}

um_skip_if_current() {
    if [ -n "$2" ] && [ "$2" = "$3" ]; then
        echo "✓ $1 is already up to date ($3)"
        exit 0
    fi
}

# Toujours téléchargé (pas de raccourci par le store).
um_prefetch_url() {
    local h
    h=$(nix store prefetch-file --json "$1" 2>/dev/null | jq -er '.hash') \
        || um_die "could not prefetch $1"
    printf '%s\n' "$h"
}

# Par le nix courant (pas de registre non verrouillé).
um_prefetch_gh() {
    local h
    h=$(nix flake prefetch --json "github:$1/$2" 2>/dev/null | jq -er '.hash') \
        || um_die "could not prefetch github:$1/$2"
    printf '%s\n' "$h"
}

# mktemp crée en 0600 : le mode est conservé.
um_replace() {
    local file="$1" tmp
    shift
    tmp=$(mktemp "$file.XXXXXX")
    if ! "$@" >"$tmp"; then
        rm -f "$tmp"
        um_die "could not write $file"
    fi
    chmod --reference="$file" "$tmp" 2>/dev/null || chmod 644 "$tmp"
    mv "$tmp" "$file"
}

um_write_pinned() {
    local args=() kv
    for kv in "$@"; do
        args+=(--arg "${kv%%=*}" "${kv#*=}")
    done
    # shellcheck disable=SC2016 # $ARGS est du jq, pas du shell
    um_replace "$UM_PINNED" jq -n '$ARGS.named' "${args[@]}"
}
