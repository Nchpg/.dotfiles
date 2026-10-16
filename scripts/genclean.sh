#!/usr/bin/env bash

# Nettoyage des générations NixOS, puis GC / optimise et rebuild. Lançable de
# n'importe où via la commande `genclean` (cf. scripts/default.nix).
#
# Toutes les questions sont posées d'abord (menus gum), puis tout s'enchaîne
# sans attendre : on n'est plus bloqué devant une étape longue pour choisir
# la suivante. Étapes :
#   1. SYSTÈME : garder N générations (ou X jours) — points de rollback du boot.
#   2. HOME-MANAGER (à cocher) : ne garder que la génération courante de chaque user.
#      Sûr : la config HM de chaque génération système gardée est rootée par
#      cette génération système (dans sa closure), donc protégée du GC. On ne
#      supprime que des pointeurs d'historique (jamais une config rollback-able).
#   3. GARBAGE COLLECT (à cocher) : libère l'espace des chemins devenus orphelins.
#   4. OPTIMISE (à cocher) : déduplique le store via des hardlinks.
#   5. REBUILD : rafraîchit le menu de boot (systemd-boot).
#
# Les chemins HM sont résolus à l'exécution (XDG sinon legacy per-user) → portable.
set -euo pipefail

case "${1:-}" in
    "") ;;
    -h|--help) sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "genclean : aucun argument attendu (genclean --help)" >&2; exit 1 ;;
esac

SYSTEM_PROFILE="/nix/var/nix/profiles/system"

here="$(dirname "$0")"
# shellcheck source=scripts/lib/env.sh
. "$here/lib/env.sh"
# shellcheck source=scripts/lib/ui.sh
. "$here/lib/ui.sh"

fancy=0
ui_fancy && fancy=1

abort() { echo "Annulé, rien n'a été modifié." >&2; exit 130; }

me="$(id -un)"

run_as() {
    local user="$1"; shift
    if [ "$user" = "$me" ]; then
        "$@"
    else
        sudo -u "$user" -H "$@"
    fi
}

# ^[1-9] et non ^[0-9] : « 0d » ou « +0 » supprimerait tout l'historique de rollback.
ask_int() {
    local header="$1" placeholder="$2" v
    while :; do
        if [ "$fancy" -eq 1 ]; then
            v=$(gum input --header "$header" --placeholder "$placeholder" --prompt "› ") || abort
        else
            read -r -p "$header : " v
        fi
        [[ "$v" =~ ^[1-9][0-9]*$ ]] && { echo "$v"; return; }
        err "'$v' : entier ≥ 1 attendu."
    done
}

gens=$(find "$(dirname "$SYSTEM_PROFILE")" -maxdepth 1 -name 'system-*-link' | wc -l)
echo "Générations système actuelles : $gens"

O_KEEP="Garder les N générations les plus récentes"
O_DAYS="Supprimer les générations de plus de X jours"
if [ "$fancy" -eq 1 ]; then
    choice=$(gum choose --header "Nettoyage des générations système" --cursor "› " \
        "$O_KEEP" "$O_DAYS") || abort
else
    echo "1) $O_KEEP"
    echo "2) $O_DAYS"
    read -r -p "Votre choix (1 ou 2) : " c
    case "$c" in
        1) choice="$O_KEEP" ;;
        2) choice="$O_DAYS" ;;
        *) err "Choix invalide."; exit 1 ;;
    esac
fi
if [ "$choice" = "$O_KEEP" ]; then
    N=$(ask_int "Nombre de générations à garder" "ex. 5")
    sys_desc="garder les $N générations les plus récentes"
    sys_arg="+$N"
else
    DAYS=$(ask_int "Nombre de jours" "ex. 14")
    sys_desc="supprimer les générations de plus de $DAYS jours"
    sys_arg="${DAYS}d"
fi

S_PROFILES="Purger l'historique des profils utilisateur (garder la génération courante)"
S_HMBACKUP="Supprimer les fichiers *.hm-backup laissés par home-manager"
S_GC="Garbage collection (libérer l'espace disque)"
S_OPTIMISE="Optimiser le store (déduplication par hardlinks, peut être long)"
declare -A STEP=()
if [ "$fancy" -eq 1 ]; then
    picked=$(gum choose --no-limit --header "Étapes en plus   (espace : cocher, entrée : valider)" \
        --cursor-prefix "› " --selected-prefix "◉ " --unselected-prefix "○ " \
        --selected="$S_PROFILES,$S_GC" \
        "$S_PROFILES" "$S_HMBACKUP" "$S_GC" "$S_OPTIMISE") || abort
    while IFS= read -r l; do [ -n "$l" ] && STEP["$l"]=1; done <<<"$picked"
else
    for s in "$S_PROFILES" "$S_HMBACKUP" "$S_GC" "$S_OPTIMISE"; do
        confirm "$s ?" && STEP["$s"]=1
    done
fi
has_rebuild=0
command -v rebuild >/dev/null 2>&1 && has_rebuild=1

echo
echo "À faire :"
echo "  • système : $sys_desc"
for s in "$S_PROFILES" "$S_HMBACKUP" "$S_GC" "$S_OPTIMISE"; do
    [ -n "${STEP[$s]:-}" ] && echo "  • $s"
done
[ "$has_rebuild" -eq 1 ] && echo "  • rebuild (menu de boot)"
echo
if [ "$fancy" -eq 1 ]; then
    gum confirm "Lancer ?" --affirmative "Oui" --negative "Non" || abort
fi

sudo -v

echo "→ Système : $sys_desc..."
sudo nix-env -p "$SYSTEM_PROFILE" --delete-generations "$sys_arg"

if [ -n "${STEP[$S_PROFILES]:-}" ]; then
    mapfile -t HM_USERS < <(
        systemctl list-unit-files --no-legend 'home-manager-*.service' 2>/dev/null \
            | sed -n 's/^home-manager-\(.*\)\.service.*/\1/p'
    )

    if [ "${#HM_USERS[@]}" -eq 0 ]; then
        warn "Aucun service home-manager détecté — purge HM ignorée."
    else
        for u in "${HM_USERS[@]}"; do
            echo "→ HM[$u] : purge de l'historique (on garde la génération courante)..."
            # shellcheck disable=SC2016 # le bloc s'exécute sous l'user $u : $HOME doit s'étendre là-bas
            run_as "$u" bash -c '
                if   [ -d "$HOME/.local/state/nix/profiles" ]; then
                     dir="$HOME/.local/state/nix/profiles"                     # XDG
                elif [ -d "/nix/var/nix/profiles/per-user/$(id -un)" ]; then
                     dir="/nix/var/nix/profiles/per-user/$(id -un)"            # legacy
                else
                     printf "\033[1;33m   profils introuvables, ignoré.\033[0m\n"; exit 0
                fi
                for name in home-manager profile; do
                     p="$dir/$name"
                     if [ ! -e "$p" ]; then
                          printf "\033[1;33m   %s absent, ignoré.\033[0m\n" "$p"; continue
                     fi
                     echo "   profil : $p"
                     nix-env -p "$p" --delete-generations old
                done
            ' || warn "   ⚠️  purge des profils de $u échouée, on continue."
        done
    fi
else
    echo "Purge home-manager ignorée."
fi

# HM renomme l'ancien fichier en *.hm-backup à chaque collision : ils s'accumulent.
if [ -n "${STEP[$S_HMBACKUP]:-}" ]; then
    for d in /home/*/ /root/; do
        [ -d "$d" ] || continue
        u="$(stat -c %U "$d")"
        echo "→ hm-backup[$u] : recherche dans $d ..."
        # shellcheck disable=SC2016 # le bloc s'exécute sous l'user $u : $HOME doit s'étendre là-bas
        run_as "$u" bash -c '
            mapfile -d "" -t found < <(find "$HOME" -xdev -name "*.hm-backup" -type f -print0 2>/dev/null)
            if [ "${#found[@]}" -eq 0 ]; then echo "   aucun fichier."; exit 0; fi
            printf "   %s\n" "${found[@]}"
            rm -f -- "${found[@]}"
            echo "   supprimés."
        ' || warn "   ⚠️  nettoyage hm-backup[$u] échoué, on continue."
    done
else
    echo "Nettoyage hm-backup ignoré."
fi

if [ -n "${STEP[$S_GC]:-}" ]; then
    echo "Garbage collection..."
    sudo nix-collect-garbage
else
    echo "Garbage collection ignoré."
fi

if [ -n "${STEP[$S_OPTIMISE]:-}" ]; then
    echo "Optimisation du store..."
    sudo nix-store --optimise
else
    echo "Optimisation ignorée."
fi

if [ "$has_rebuild" -eq 1 ]; then
    echo "Rebuild du système via la commande rebuild..."
    rebuild -y
else
    warn "Commande 'rebuild' introuvable — relance './scripts/rebuild.sh --profile <profil> --host <host>' à la main pour rafraîchir le menu de boot."
fi

echo "Nettoyage terminé."
