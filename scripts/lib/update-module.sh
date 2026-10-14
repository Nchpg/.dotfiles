# shellcheck shell=bash disable=SC2034 # UM_* : lues par les scripts qui sourcent ce fichier
# Bibliothèque commune des `update.sh` de modules (modules épinglés :
# pinned.json, extensions.json...). Sourcée en tête de chaque script :
#
#   # shellcheck source=scripts/lib/update-module.sh
#   . "${MY_FLAKE:-$HOME/.dotfiles}/scripts/lib/update-module.sh"
#   um_init "$@"
#
# Même racine que celle où les scripts écrivent : MY_FLAKE est posé par
# scripts/update.sh (commande `update`, ou `rebuild -u`) comme par la CI
# hebdo (.github/workflows/update.yml), qui lancent tous deux les update.sh
# auto-découverts (`find modules -name update.sh`).
#
# Protocole attendu par scripts/update.sh :
#   - sans option : met à jour pour de bon (télécharge, hache, réécrit le
#     fichier épinglé) ;
#   - --check : affiche {name, current, latest, url} en JSON sur stdout (fd 3
#     ici, cf. um_init), sans rien télécharger ni modifier. Sert à tout lister
#     avant de choisir ; le reste des messages part alors sur stderr. Champs
#     facultatifs lus par update.sh : available, note, summary, items ;
#   - --only KEY... : ne traite que ces sous-éléments (modules à `items`,
#     ex. une extension VS Code par clé).
# Un échec reste local au module : code de retour non nul, fichier épinglé
# intact (écriture atomique, cf. um_replace).

# Variables posées par um_init, lues par les scripts :
#   UM_CHECK  : 1 en --check, 0 sinon
#   UM_ONLY   : clés passées à --only (tableau, vide = toutes)
#   UM_FLAKE  : racine du dépôt
#   UM_DIR    : dossier du module (celui du script)
#   UM_PINNED : $UM_DIR/pinned.json
#   UM_AUTH   : en-tête du jeton GitHub pour curl (tableau, vide sans jeton)
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

    # Jeton facultatif (GITHUB_TOKEN, exporté par update.sh depuis gh ou par
    # la CI) : sans lui l'API GitHub plafonne à 60 requêtes/h par IP, vite
    # atteint sur un runner partagé, et le 403 qui s'ensuit faisait échouer
    # le module.
    UM_AUTH=()
    [ -n "${GITHUB_TOKEN:-}" ] && UM_AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN")
    return 0
}

um_die() {
    echo "⚠️ Error: $*" >&2
    exit 1
}

# um_curl URL [OPTIONS curl...] : GET silencieux, échec sur code HTTP >= 400.
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

# um_pinned KEY : valeur de KEY dans pinned.json, vide si absente (ou fichier
# absent : premier épinglage).
um_pinned() {
    jq -r --arg k "$1" '.[$k] // empty' "$UM_PINNED" 2>/dev/null || true
}

# Dernières versions publiées. jq -e + // empty : réponse inattendue (rate
# limit, paquet inconnu...) -> échec explicite plutôt qu'une version "null"
# et une URL ...vnull... plus loin.
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

# um_latest_gh_release OWNER/REPO : tag de la dernière release, sans le « v ».
um_latest_gh_release() {
    local v
    v=$(um_curl "https://api.github.com/repos/$1/releases/latest" | jq -er '.tag_name // empty | ltrimstr("v")') \
        && [ -n "$v" ] || um_die "could not read latest release of $1 (GitHub)"
    printf '%s\n' "$v"
}

# um_check NAME CURRENT LATEST [URL] [NOTE] : émet le JSON de --check et
# termine. NOTE n'est émise que si elle est passée (même vide).
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

# um_skip_if_current LABEL CURRENT LATEST : rien à faire si déjà épinglé.
um_skip_if_current() {
    if [ -n "$2" ] && [ "$2" = "$3" ]; then
        echo "✓ $1 is already up to date ($3)"
        exit 0
    fi
}

# um_prefetch_url URL : hash SRI (sha256-...) du fichier, tel qu'attendu par
# fetchurl. Télécharge TOUJOURS (pas de raccourci par le store) : le hash
# correspond à l'artefact réellement servi.
um_prefetch_url() {
    local h
    h=$(nix store prefetch-file --json "$1" 2>/dev/null | jq -er '.hash') \
        || um_die "could not prefetch $1"
    printf '%s\n' "$h"
}

# um_prefetch_gh OWNER/REPO REV : hash NAR de l'archive GitHub, le même que
# fetchFromGitHub. `nix flake prefetch` vient du nix courant : pas de
# `nix run nixpkgs#...`, qui dépendrait du registre (non verrouillé).
um_prefetch_gh() {
    local h
    h=$(nix flake prefetch --json "github:$1/$2" 2>/dev/null | jq -er '.hash') \
        || um_die "could not prefetch github:$1/$2"
    printf '%s\n' "$h"
}

# um_replace FICHIER CMD... : remplace FICHIER par la sortie de CMD, de façon
# atomique (tmp à côté + mv) : jamais de fichier à moitié écrit si le script
# est interrompu ou si CMD échoue. Le mode du fichier existant est conservé
# (mktemp crée en 0600).
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

# um_write_pinned KEY=VALEUR... : réécrit pinned.json (chaînes, dans l'ordre
# donné). jq échappe les valeurs, contrairement à l'ancien heredoc.
um_write_pinned() {
    local args=() kv
    for kv in "$@"; do
        args+=(--arg "${kv%%=*}" "${kv#*=}")
    done
    # shellcheck disable=SC2016 # $ARGS est du jq, pas du shell
    um_replace "$UM_PINNED" jq -n '$ARGS.named' "${args[@]}"
}
