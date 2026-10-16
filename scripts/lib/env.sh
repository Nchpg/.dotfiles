# shellcheck shell=bash disable=SC2034 # flake, DOTS_* : lus par les scripts qui sourcent ce fichier
# config.sh est lu depuis le store (hors d'atteinte d'un environnement trafiqué) ; absent d'un clone.

_dots_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_dots_root="$(cd "$_dots_lib/../.." && pwd)"
if [[ "$_dots_root" != /nix/store/* ]] && [ -f "$_dots_root/flake.nix" ]; then
    flake="$_dots_root"
else
    flake="${MY_FLAKE:-$HOME/.dotfiles}"
fi

if [ -f "$_dots_lib/config.sh" ]; then
    # shellcheck source=/dev/null
    . "$_dots_lib/config.sh"
fi
unset _dots_lib _dots_root

require_flake() {
    if [ ! -f "$flake/flake.nix" ]; then
        echo "$1 : dépôt de config introuvable ($flake) — clone-le ou définis MY_FLAKE." >&2
        exit 1
    fi
}
