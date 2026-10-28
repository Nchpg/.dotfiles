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

# sudo : une fois le mot de passe donné, le ticket est rafraîchi chaque minute (`sudo -n -v`) tant que
# le script tourne. Les sudo suivants (après un long passage dans l'éditeur, par exemple) ne le
# redemandent pas ; le ticket reste celui du terminal, et expire normalement après la fin du script.
sudo() {
    local rc=0 lock="${XDG_RUNTIME_DIR:-/tmp}/dots-sudo.$$"
    command sudo "$@" || rc=$?
    # Une seule boucle par script, même lancée depuis un $(…) : le verrou est un dossier.
    if [ "$rc" = 0 ] && mkdir "$lock" 2> /dev/null; then
        # Descripteurs fermés : un sudo dans un $(…) n'attend pas la fin de la boucle.
        (
            trap 'rmdir "$lock"' EXIT
            while sleep 60 && kill -0 "$$" 2> /dev/null; do
                command sudo -n -v 2> /dev/null || exit 0
            done
        ) < /dev/null > /dev/null 2>&1 &
    fi
    return "$rc"
}
