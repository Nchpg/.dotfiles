# shellcheck shell=bash disable=SC2034 # flake, DOTS_* : lus par les scripts qui sourcent ce fichier
# Contexte commun des commandes du dépôt, sourcé en tête de chacune :
#
#   # shellcheck source=scripts/lib/env.sh
#   . "$(dirname "$0")/lib/env.sh"
#
# Deux choses.
#
# LE DÉPÔT SUR LEQUEL AGIR (`flake`). Lancé depuis un clone
# (./scripts/rebuild.sh), c'est ce clone-là : on agit sur le code qu'on vient
# de lancer. Lancé depuis le paquet installé (la commande `rebuild` du PATH,
# cf. scripts/default.nix), le script vit dans le store : c'est alors
# $MY_FLAKE, sinon ~/.dotfiles.
#
# LES VALEURS PROPRES À CE SYSTÈME (cible, palette, ancre sops, binaires
# figés…), dans lib/config.sh : généré par le paquet, absent d'un clone. Lu
# depuis le store, donc hors d'atteinte d'un environnement trafiqué — ce que
# `secrets` exige, cf. son en-tête. Sans lui, chaque script a ses défauts
# (cible à passer en argument, couleurs du terminal), sauf `secrets` qui
# refuse de tourner.

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

# require_flake <commande> : échec net si le dépôt est introuvable, plutôt
# qu'un « No such file » obscur plus loin (user sans clone : ~guest, sudo -i).
require_flake() {
    if [ ! -f "$flake/flake.nix" ]; then
        echo "$1 : dépôt de config introuvable ($flake) — clone-le ou définis MY_FLAKE." >&2
        exit 1
    fi
}
