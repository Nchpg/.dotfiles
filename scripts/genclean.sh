#!/usr/bin/env bash

# Nettoyage des générations NixOS, puis GC / optimise et rebuild. Lançable de
# n'importe où via la commande `genclean` (cf. modules/system/commands/genclean).
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

# Aucun argument : sans ce garde, `genclean --help` (proposé par `dots`) lançait
# directement le nettoyage. L'aide est l'en-tête ci-dessus.
case "${1:-}" in
    "") ;;
    -h|--help) sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "genclean : aucun argument attendu (genclean --help)" >&2; exit 1 ;;
esac

SYSTEM_PROFILE="/nix/var/nix/profiles/system"

# On se place dans le flake pour que `nixos-rebuild --flake .` fonctionne quel
# que soit le répertoire d'appel.
cd "$(dirname "$0")/.."

RED='\033[0;31m'
ORANGE='\033[1;33m'
NC='\033[0m'

err()  { echo -e "${RED}$*${NC}" >&2; }      # erreurs (rouge)
warn() { echo -e "${ORANGE}$*${NC}" >&2; }   # avertissements (orange)

# Palette : fournie par la commande `genclean` (Stylix, cf. lib/mk-update-env.nix),
# valeurs par défaut sinon. gum seulement vers un terminal ; sans lui (appel
# direct du script hors rebuild), questions en read classiques.
C_ACCENT="${UPDATE_COLOR_ACCENT:-#7aa2f7}"
C_OK="${UPDATE_COLOR_OK:-#9ece6a}"
C_TEXT="${UPDATE_COLOR_TEXT:-#c0caf5}"
export GUM_CHOOSE_CURSOR_FOREGROUND="$C_ACCENT"
export GUM_CHOOSE_SELECTED_FOREGROUND="$C_OK"
export GUM_CHOOSE_HEADER_FOREGROUND="$C_ACCENT"
export GUM_CHOOSE_ITEM_FOREGROUND="$C_TEXT"
export GUM_INPUT_CURSOR_FOREGROUND="$C_ACCENT"
export GUM_INPUT_PROMPT_FOREGROUND="$C_ACCENT"
export GUM_INPUT_HEADER_FOREGROUND="$C_ACCENT"
export GUM_CONFIRM_PROMPT_FOREGROUND="$C_ACCENT"
export GUM_CONFIRM_SELECTED_BACKGROUND="$C_ACCENT"

fancy=0
if [ -t 0 ] && [ -t 1 ] && command -v gum >/dev/null 2>&1; then
    fancy=1
fi

# Ctrl+C / Échap dans un menu gum : on abandonne tout, rien n'a encore été fait.
abort() { echo "Annulé, rien n'a été modifié." >&2; exit 130; }

me="$(id -un)"

# Exécute une commande en tant que $user (sans sudo si c'est déjà nous).
run_as() {
    local user="$1"; shift
    if [ "$user" = "$me" ]; then
        "$@"
    else
        sudo -u "$user" -H "$@"
    fi
}

# Pose une question oui/non (défaut : non). Renvoie 0 si oui. (Repli sans gum.)
ask_yn() {
    local reply
    read -p "$1 [y/N] " -n 1 -r reply
    echo
    [[ "$reply" =~ ^[YyOo]$ ]]
}

# Demande un entier ≥ 1, redemande tant qu'il est invalide. ^[1-9] et pas
# ^[0-9] : « 0d » ou « +0 » supprimerait TOUT l'historique de rollback d'un
# coup, alors que préserver ces points de retour est justement l'objet de ce
# script.
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

# --- Questions, toutes d'avance ----------------------------------------------
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
    # Préselection : profils + GC, le nettoyage habituel ; hm-backup (supprime
    # des fichiers) et optimise (long) se cochent à la demande.
    picked=$(gum choose --no-limit --header "Étapes en plus   (espace : cocher, entrée : valider)" \
        --cursor-prefix "› " --selected-prefix "◉ " --unselected-prefix "○ " \
        --selected="$S_PROFILES,$S_GC" \
        "$S_PROFILES" "$S_HMBACKUP" "$S_GC" "$S_OPTIMISE") || abort
    while IFS= read -r l; do [ -n "$l" ] && STEP["$l"]=1; done <<<"$picked"
else
    for s in "$S_PROFILES" "$S_HMBACKUP" "$S_GC" "$S_OPTIMISE"; do
        ask_yn "$s ?" && STEP["$s"]=1
    done
fi
has_rebuild=0
command -v rebuild >/dev/null 2>&1 && has_rebuild=1

# Récapitulatif avant de lancer, puis plus aucune question.
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

# sudo demandé maintenant, pas au milieu d'une étape longue.
sudo -v

# --- 1. Profil SYSTÈME -------------------------------------------------------
echo "→ Système : $sys_desc..."
sudo nix-env -p "$SYSTEM_PROFILE" --delete-generations "$sys_arg"

# --- 2. Profils utilisateur : home-manager ET profile (optionnel) -----------
if [ -n "${STEP[$S_PROFILES]:-}" ]; then
    # Users détectés via les services générés par le module HM (portable).
    mapfile -t HM_USERS < <(
        systemctl list-unit-files --no-legend 'home-manager-*.service' 2>/dev/null \
            | sed -n 's/^home-manager-\(.*\)\.service.*/\1/p'
    )

    if [ "${#HM_USERS[@]}" -eq 0 ]; then
        warn "Aucun service home-manager détecté — purge HM ignorée."
    else
        for u in "${HM_USERS[@]}"; do
            echo "→ HM[$u] : purge de l'historique (on garde la génération courante)..."
            # Résolution du chemin + purge EN TANT QUE $u : on lit ainsi son
            # $HOME (même protégé) et on préserve les permissions du profil.
            # shellcheck disable=SC2016 # single quotes voulues : ce bloc s'exécute
            # dans le bash de run_as (sous l'user $u), pas ici -> $HOME/$p/... doivent
            # s'étendre là-bas, pas dans CE shell (qui n'a pas le bon $HOME).
            run_as "$u" bash -c '
                if   [ -d "$HOME/.local/state/nix/profiles" ]; then
                     dir="$HOME/.local/state/nix/profiles"                     # XDG
                elif [ -d "/nix/var/nix/profiles/per-user/$(id -un)" ]; then
                     dir="/nix/var/nix/profiles/per-user/$(id -un)"            # legacy
                else
                     printf "\033[1;33m   profils introuvables, ignoré.\033[0m\n"; exit 0
                fi
                # DEUX profils accumulent une génération par rebuild, pas un :
                #   home-manager : la génération HM elle-même
                #   profile      : les user-environment (nix profile / nix-env)
                # Ne purger que le premier laissait le second croître sans fin.
                # Constaté sur guest : 325 générations `profile` retenant 304
                # closures distinctes, soit ~20 000 chemins que le GC ne pouvait
                # pas libérer — alors que son historique HM était bien purgé.
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

# --- 2bis. Fichiers *.hm-backup (optionnel) ----------------------------------
# home-manager.backupFileExtension = "hm-backup" : à chaque collision, HM
# renomme l'ancien fichier en *.hm-backup au lieu d'échouer. Ils s'accumulent.
if [ -n "${STEP[$S_HMBACKUP]:-}" ]; then
    for d in /home/*/ /root/; do
        [ -d "$d" ] || continue
        u="$(stat -c %U "$d")"
        echo "→ hm-backup[$u] : recherche dans $d ..."
        # -print0 / mapfile -d "" : robuste aux noms de fichiers exotiques
        # (espaces, voire newlines), contrairement à l'ancien xargs -d "\n".
        # shellcheck disable=SC2016 # single quotes voulues : ce bloc s'exécute
        # dans le bash de run_as (sous l'user $u), pas ici -> $HOME doit s'étendre
        # là-bas, pas dans CE shell (qui n'a pas le bon $HOME).
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

# --- 3. Garbage collection (optionnel) --------------------------------------
# Sans -d : les générations ont déjà été purgées ci-dessus à la granularité
# voulue. Le GC libère juste l'espace des chemins devenus orphelins.
if [ -n "${STEP[$S_GC]:-}" ]; then
    echo "Garbage collection..."
    sudo nix-collect-garbage
else
    echo "Garbage collection ignoré."
fi

# --- 4. Optimisation du store (optionnel) -----------------------------------
if [ -n "${STEP[$S_OPTIMISE]:-}" ]; then
    echo "Optimisation du store..."
    sudo nix-store --optimise
else
    echo "Optimisation ignorée."
fi

# --- 5. Rebuild pour rafraîchir le menu de boot (systemd-boot) ---------------
# La commande `rebuild` vient de modules/system/rebuild : absente si le module
# n'a pas encore été switché (repo fraîchement cloné) — on prévient au lieu
# d'échouer sur la dernière étape.
if [ "$has_rebuild" -eq 1 ]; then
    echo "Rebuild du système via la commande rebuild..."
    rebuild -y
else
    warn "Commande 'rebuild' introuvable — relance './scripts/rebuild.sh --profile <profil> --host <host>' à la main pour rafraîchir le menu de boot."
fi

echo "Nettoyage terminé."
