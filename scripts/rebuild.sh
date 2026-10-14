#!/usr/bin/env bash

set -euo pipefail

# Défauts : posés par la commande `rebuild` (cf. modules/system/commands/rebuild)
# avec la cible qui a construit ce système. Appel direct du script : aucun,
# --host et --profile sont alors obligatoires.
PROFILE="${REBUILD_DEFAULT_PROFILE:-}"
HOST="${REBUILD_DEFAULT_HOST:-}"
VARIANT="${REBUILD_DEFAULT_VARIANT:-dark}"
UPDATE=0
YES=0

usage() {
    echo "usage: rebuild [-p PROFILE] [-H HOST] [-V dark|light] [-u|--update] [-y|--yes]"
    if [[ -n "${REBUILD_DEFAULT_PROFILE:-}" ]]; then
        echo "  défaut (cible de ce système) : --profile $REBUILD_DEFAULT_PROFILE --host $REBUILD_DEFAULT_HOST --variant $VARIANT"
    else
        echo "  -p/--profile et -H/--host obligatoires (pas de cible par défaut hors de la commande \`rebuild\`)"
    fi
    echo "  -V : variante de thème (la commande \`theme\` s'en sert pour toggler)"
    echo "  -u : lance \`update\` (modules à update.sh + inputs du flake, au"
    echo "       choix) avant le rebuild"
    echo "  -y : aucune confirmation (working tree sale, modules -u) ; ne"
    echo "       touche JAMAIS au lock des secrets (avertit seulement)"
}

# Un seul parsing, formes courtes et longues : la commande `rebuild` ne fait
# que poser les défauts et relayer les arguments tels quels.
# need_value : sous `set -u`, un `--host` sans valeur mourait sur un
# « $2: unbound variable » au lieu d'un message clair.
need_value() {
    [[ $# -ge 2 ]] || { echo "rebuild : option $1 sans valeur" >&2; exit 1; }
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--profile) need_value "$@"; PROFILE="$2"; shift 2 ;;
        -H|--host)    need_value "$@"; HOST="$2";    shift 2 ;;
        -V|--variant) need_value "$@"; VARIANT="$2"; shift 2 ;;
        -u|--update)  UPDATE=1; shift ;;
        -y|--yes)     YES=1;    shift ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "argument inconnu : $1" >&2; exit 1 ;;
    esac
done

# Vérification obligatoire
if [[ -z "$HOST" || -z "$PROFILE" ]]; then
    usage >&2
    exit 1
fi

case "$VARIANT" in
    dark|light) ;;
    *) echo "Variante invalide : $VARIANT (attendu : dark ou light)" >&2; exit 1 ;;
esac

# Nom de la cible du flake : la variante dark garde le nom historique
# (personal-gram), light suffixe (personal-gram-light) — même calcul que
# lib/target-name.nix (`full`), qui nomme les nixosConfigurations.
ATTR="$PROFILE-$HOST"
if [[ "$VARIANT" != "dark" ]]; then
    ATTR="$ATTR-$VARIANT"
fi

cd "$(dirname "$0")/.."

# Couleurs et questions : cf. lib/ui.sh ; hooks git : cf. lib/hooks.sh.
# shellcheck source=scripts/lib/ui.sh
. scripts/lib/ui.sh
# shellcheck source=scripts/lib/hooks.sh
. scripts/lib/hooks.sh

# Mises à jour seulement sur demande (--update / rebuild -u) : les faire à
# chaque rebuild salissait flake.lock (→ warning git systématique). Délégué à
# update.sh (aussi lançable seul via `update`) : vérifie tout en parallèle,
# puis propose modules épinglés et inputs du flake à cocher. Garde-fou
# conservé : contrairement à la CI (PR relue avant merge), un `rebuild -u`
# enchaîne directement sur le switch, donc rien ne s'applique sans choix
# explicite — sauf --yes (genclean), qui prend la sélection par défaut
# (modules + claude-code). Jamais fatal : un échec garde l'état précédent.
if [[ "$UPDATE" -eq 1 ]]; then
    update_args=()
    [[ "$YES" -eq 1 ]] && update_args+=(--yes)
    # Ctrl+C dans la liste (130) : on abandonne aussi le rebuild. Tout autre
    # échec : on reconstruit avec l'état actuel.
    UPDATE_FROM_REBUILD=1 ./scripts/update.sh "${update_args[@]}" && rc=0 || rc=$?
    if [[ "$rc" -eq 130 ]]; then
        echo "Rebuild annulé."
        exit 130
    elif [[ "$rc" -ne 0 ]]; then
        echo "⚠️  update en échec — rebuild avec l'état actuel."
    fi
fi


echo "🔎 Checking Git status before rebuild..."

if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    err "Error: Not a Git repository. Cannot check for uncommitted changes."
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "${WARN}Warning: uncommitted changes or untracked files in the working tree.${R}"
    echo "------------------------------------------------------------------"
    git status --short
    echo "------------------------------------------------------------------"
    # Rappel du comportement flake : les modifs des fichiers TRACKÉS sont bien
    # incluses même non commitées ; seuls les fichiers NON TRACKÉS sont ignorés.
    echo "Note: modified tracked files ${OK}ARE included${R} in the build; ${ERR}untracked files are NOT${R} (git add them first)."
    echo
    # --yes : pas de confirmation (utilisé par genclean pour son rebuild final
    # automatique ; `theme` ne modifie plus aucun fichier depuis que la
    # variante est portée par la cible du flake).
    if [[ "$YES" -eq 1 ]]; then
        echo "(--yes) Continuing without confirmation."
    else
        if ! confirm "Continue anyway?" no; then
            echo "${ERR}Rebuild aborted by user.${R}"
            exit 1
        fi
    fi
else
    echo "${OK}✅ Git status is clean.${R}"
fi

# ── Cohérence du dépôt de secrets ────────────────────────────────────────────
#
# Le lock épingle l'entrée `secrets`, donc une valeur modifiée là-bas n'est PAS
# déployée tant que le lock ici n'a pas bougé (`secrets sync`). C'est
# voulu — sans ça, éditer le dépôt privé suffirait à changer ce que les machines
# déploient. Mais la contrepartie est un rebuild qui réussit en installant
# l'ANCIENNE valeur, sans un message.
#
# Ça a coûté une base Authelia illisible, un tunnel Cloudflare hors service et
# deux clés WireGuard désynchronisées en une soirée. On compare donc, ici, au
# moment qui compte.
#
# Tout passe par la commande `secrets` (modules/system/commands/secrets), seule
# à lire le lock et à le mettre à jour : `status` sort en 1 quand `sync` a du
# travail (modifications, commits non poussés, lock en retard sur le dépôt), en
# 2 quand il en a mais refuserait (dépôt privé en retard : pull d'abord).
# Sans réseau, donc sans phrase de passe SSH à chaque rebuild. Absente sur une
# machine neuve avant son premier rebuild, où le clone est de toute façon frais.
# `secrets help` : une commande antérieure (machine pas encore rebuildée) n'a
# pas `status`, et son « commande inconnue » passait pour une désynchro.
if command -v secrets > /dev/null && [[ "$(secrets help 2>&1)" == *"secrets status"* ]]; then
    secrets_rc=0
    secrets status || secrets_rc=$?
    if [[ "$secrets_rc" -eq 2 ]]; then
        # `sync` refuserait (dépôt en retard) : rien à proposer ici, le détail
        # et la marche à suivre viennent d'être affichés.
        echo "${WARN}Modifications de secrets non déployables avant un pull du dépôt privé ; poursuite avec la révision épinglée.${R}"
    elif [[ "$secrets_rc" -ne 0 ]]; then
        echo "  Rebuild en l'état = ${ERR}déploiement de l'ANCIENNE valeur${R}."
        echo
        # --yes (genclean) ne bouge JAMAIS ce lock : une maintenance
        # de générations n'a pas à déployer de nouvelles valeurs de secrets
        # sans qu'on l'ait demandé. Avertissement seul, révision épinglée.
        if [[ "$YES" -eq 1 ]]; then
            echo "${WARN}(--yes) Lock non modifié, poursuite avec la révision épinglée.${R}"
            echo "  Pour déployer la nouvelle : \`secrets sync\`, ou rebuild sans --yes."
        else
            if confirm "Synchroniser maintenant (secrets sync) ?" yes; then
                secrets sync || {
                    err "Synchronisation des secrets échouée."
                    exit 1
                }
            else
                echo "${WARN}Poursuite avec la révision épinglée.${R}"
            fi
        fi
    fi
fi

echo "🚀 Starting NixOS system rebuild..."

# Génération courante avant le switch, pour afficher le diff des paquets après.
PREV_SYSTEM="$(readlink -f /run/current-system)"

# Pas de --impure : la config est pure (aucun getEnv/lecture impure), et --impure
# désactiverait le cache d'évaluation -> chaque rebuild réévaluerait tout de zéro.
# Pas de --show-trace par défaut : il ralentit nettement l'éval. Pour déboguer une
# erreur d'éval, relancer ponctuellement via : REBUILD_EXTRA_ARGS=--show-trace rebuild
# Split volontaire de REBUILD_EXTRA_ARGS en mots, via un tableau (et pas une
# expansion non quotée, qui subirait aussi l'expansion des globs).
read -ra EXTRA_ARGS <<< "${REBUILD_EXTRA_ARGS:-}"

# NIX_CONFIG posé ici plutôt que d'exiger une invocation particulière le jour où
# l'on enrôle une machine.
#
# L'entrée `secrets` vit dans un dépôt privé, donc sa récupération demande le
# jeton rangé dans ce fichier. C'est ce que fait `nix.extraOptions` (cf.
# modules/system/configuration.nix), sauf que cette configuration n'atterrit dans
# /etc/nix/nix.conf qu'à l'ACTIVATION — laquelle a besoin de l'entrée, qui a
# besoin du jeton. Sur une machine neuve, le premier rebuild échouait donc en 404
# et il fallait retaper l'include à la main.
#
# Sans effet une fois la machine à jour : inclure deux fois le même fichier pose
# deux fois le même réglage. Et un include absent est toléré par nix, donc une
# machine sans jeton (aucun dépôt privé à récupérer) n'y voit rien.
#
# ATTENTION au répertoire : s'il n'est pas traversable, nix n'ignore pas
# l'include, il jette la TOTALITÉ de /etc/nix/nix.conf. Cf. le commentaire de la
# règle tmpfiles.
if sudo NIX_CONFIG='!include /var/lib/nix/access-tokens.conf' \
    nixos-rebuild switch --flake .#"$ATTR" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}; then
    echo "✅ System rebuild successful."

    # Diff des paquets ancien système → nouveau (versions bump, ajouts, retraits).
    NEW_SYSTEM="$(readlink -f /run/current-system)"
    if [[ "$PREV_SYSTEM" != "$NEW_SYSTEM" ]] && command -v nvd > /dev/null; then
        echo "📦 Changes since previous generation:"
        nvd diff "$PREV_SYSTEM" "$NEW_SYSTEM" || true
    fi

    if [ -n "${SWAYSOCK:-}" ]; then
        echo "💨 Sway session detected. Reloading configuration..."
        # `|| true` comme pour nvd et waybar plus bas : le switch a DÉJÀ
        # réussi à ce stade, un reload raté ne doit pas tuer le script avant
        # le redémarrage de waybar ni faire croire à un rebuild en échec.
        if swaymsg reload; then
            echo "🎉 Sway reloaded."
        else
            echo "⚠️  Sway reload échoué (le rebuild, lui, est bien appliqué)." >&2
        fi

        # waybar tourne en service systemd --user : le rebuild (root) ne peut
        # pas le relancer, donc les X-Restart-Triggers / onChange du module HM
        # sont sautés. On le redémarre ici, côté utilisateur, pour qu'il reprenne
        # sa nouvelle config/couleurs. try-restart = no-op s'il ne tourne pas.
        echo "📊 Restarting waybar..."
        systemctl --user try-restart waybar.service 2>/dev/null || true
    fi
else
    err "❌ System rebuild failed. Please check the errors above."
    exit 1
fi

# ── Hooks git du dépôt ───────────────────────────────────────────────────────
#
# Cf. lib/hooks.sh. Après un rebuild, la commande `secrets` qu'ils appellent
# est à jour : c'est le bon moment pour rattraper un clone fait sans
# ./init.sh. --yes ne décide pas à ta place : avertissement seul.
if [[ "$YES" -eq 1 ]]; then
    hooks_offer "$PWD" --no-ask
else
    hooks_offer "$PWD"
fi

echo "All done."
