#!/usr/bin/env bash

# Nettoyage des générations NixOS, puis GC / optimise et rebuild. Lançable de
# n'importe où via la commande `genclean` (cf. modules/system/genclean).
#
# Étapes (les 3 dernières sont optionnelles, demandées en y/n) :
#   1. SYSTÈME : garder N générations (ou X jours) — points de rollback du boot.
#   2. HOME-MANAGER (y/n) : ne garder que la génération courante de chaque user.
#      Sûr : la config HM de chaque génération système gardée est rootée par
#      cette génération système (dans sa closure), donc protégée du GC. On ne
#      supprime que des pointeurs d'historique (jamais une config rollback-able).
#   3. GARBAGE COLLECT (y/n) : libère l'espace des chemins devenus orphelins.
#   4. OPTIMISE (y/n) : déduplique le store via des hardlinks.
#   5. REBUILD : rafraîchit le menu de boot (systemd-boot).
#
# Les chemins HM sont résolus à l'exécution (XDG sinon legacy per-user) → portable.
set -euo pipefail

SYSTEM_PROFILE="/nix/var/nix/profiles/system"

# On se place dans le flake pour que `nixos-rebuild --flake .` fonctionne quel
# que soit le répertoire d'appel.
cd "$(dirname "$0")"

RED='\033[0;31m'
ORANGE='\033[1;33m'
NC='\033[0m'

err()  { echo -e "${RED}$*${NC}" >&2; }      # erreurs (rouge)
warn() { echo -e "${ORANGE}$*${NC}" >&2; }   # avertissements (orange)

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

# Pose une question oui/non (défaut : non). Renvoie 0 si oui.
ask_yn() {
    local reply
    read -p "$1 [y/N] " -n 1 -r reply
    echo
    [[ "$reply" =~ ^[YyOo]$ ]]
}

# --- 1. Profil SYSTÈME : mode interactif (jours ou nombre) -------------------
echo "Nettoyage des générations système — choisis le mode :"
echo "1) Supprimer les générations plus anciennes que X jours"
echo "2) Ne garder que les N générations les plus récentes"
read -r -p "Votre choix (1 ou 2) : " MODE

case "$MODE" in
    1)
        read -r -p "Nombre de jours : " DAYS
        if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
            err "Erreur : '$DAYS' n'est pas un nombre valide."
            exit 1
        fi
        echo "→ Système : suppression des générations de plus de $DAYS jours..."
        sudo nix-env -p "$SYSTEM_PROFILE" --delete-generations +"$DAYS"d
        ;;
    2)
        read -r -p "Nombre de générations à garder : " N
        if ! [[ "$N" =~ ^[0-9]+$ ]]; then
            err "Erreur : '$N' n'est pas un nombre valide."
            exit 1
        fi
        echo "→ Système : on garde les $N générations les plus récentes..."
        sudo nix-env -p "$SYSTEM_PROFILE" --delete-generations +"$N"
        ;;
    *)
        err "Choix invalide."
        exit 1
        ;;
esac

# --- 2. Profils home-manager (optionnel) ------------------------------------
if ask_yn "Purger l'historique home-manager (garder seulement la génération courante) ?"; then
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
            run_as "$u" bash -c '
                if   [ -d "$HOME/.local/state/nix/profiles" ]; then
                     p="$HOME/.local/state/nix/profiles/home-manager"          # XDG
                elif [ -d "/nix/var/nix/profiles/per-user/$(id -un)" ]; then
                     p="/nix/var/nix/profiles/per-user/$(id -un)/home-manager" # legacy
                else
                     printf "\033[1;33m   profil HM introuvable, ignoré.\033[0m\n"; exit 0
                fi
                if [ ! -e "$p" ]; then
                     printf "\033[1;33m   %s absent, ignoré.\033[0m\n" "$p"; exit 0
                fi
                echo "   profil : $p"
                nix-env -p "$p" --delete-generations old
            ' || warn "   ⚠️  purge HM[$u] échouée, on continue."
        done
    fi
else
    echo "Purge home-manager ignorée."
fi

# --- 2bis. Fichiers *.hm-backup (optionnel) ----------------------------------
# home-manager.backupFileExtension = "hm-backup" : à chaque collision, HM
# renomme l'ancien fichier en *.hm-backup au lieu d'échouer. Ils s'accumulent.
if ask_yn "Supprimer les fichiers *.hm-backup laissés par home-manager ?"; then
    for d in /home/*/ /root/; do
        [ -d "$d" ] || continue
        u="$(stat -c %U "$d")"
        echo "→ hm-backup[$u] : recherche dans $d ..."
        # -print0 / mapfile -d "" : robuste aux noms de fichiers exotiques
        # (espaces, voire newlines), contrairement à l'ancien xargs -d "\n".
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
if ask_yn "Lancer le garbage collection (libérer l'espace disque) ?"; then
    echo "Garbage collection..."
    sudo nix-collect-garbage
else
    echo "Garbage collection ignoré."
fi

# --- 4. Optimisation du store (optionnel) -----------------------------------
if ask_yn "Optimiser le store (déduplication par hardlinks, peut être long) ?"; then
    echo "Optimisation du store..."
    sudo nix-store --optimise
else
    echo "Optimisation ignorée."
fi

# --- 5. Rebuild pour rafraîchir le menu de boot (systemd-boot) ---------------
# La commande `rebuild` vient de modules/system/rebuild : absente si le module
# n'a pas encore été switché (repo fraîchement cloné) — on prévient au lieu
# d'échouer sur la dernière étape.
if command -v rebuild >/dev/null 2>&1; then
    echo "Rebuild du système via la commande rebuild..."
    rebuild -y
else
    warn "Commande 'rebuild' introuvable — relance './rebuild.sh --profile <profil> --host <host>' à la main pour rafraîchir le menu de boot."
fi

echo "Nettoyage terminé."
