#!/usr/bin/env bash

set -euo pipefail

here="$(dirname "$0")"
# shellcheck source=scripts/lib/env.sh
. "$here/lib/env.sh"
# shellcheck source=scripts/lib/ui.sh
. "$here/lib/ui.sh"
# shellcheck source=scripts/lib/hooks.sh
. "$here/lib/hooks.sh"
# shellcheck source=scripts/lib/access.sh
. "$here/lib/access.sh"

PROFILE="${DOTS_PROFILE:-}"
HOST="${DOTS_HOST:-}"
VARIANT="${DOTS_VARIANT:-dark}"
UPDATE=0
YES=0

usage() {
    echo "usage: rebuild [-p PROFILE] [-H HOST] [-V dark|light] [-u|--update] [-y|--yes]"
    if [[ -n "${DOTS_PROFILE:-}" ]]; then
        echo "  défaut (cible de ce système) : --profile $DOTS_PROFILE --host $DOTS_HOST --variant $VARIANT"
    else
        echo "  -p/--profile et -H/--host obligatoires (pas de cible par défaut hors de la commande \`rebuild\`)"
    fi
    echo "  -V : variante de thème (la commande \`theme\` s'en sert pour toggler)"
    echo "  -u : lance \`update\` (modules à update.sh + inputs du flake, au"
    echo "       choix) avant le rebuild"
    echo "  -y : aucune confirmation (working tree sale, modules -u) ; ne"
    echo "       touche JAMAIS au lock des secrets (avertit seulement), et les"
    echo "       changements d'accès (sites, VPN, Authelia, SSH) demandent toujours un oui"
}

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

if [[ -z "$HOST" || -z "$PROFILE" ]]; then
    usage >&2
    exit 1
fi

case "$VARIANT" in
    dark|light) ;;
    *) echo "Variante invalide : $VARIANT (attendu : dark ou light)" >&2; exit 1 ;;
esac

ATTR="$PROFILE-$HOST"
if [[ "$VARIANT" != "dark" ]]; then
    ATTR="$ATTR-$VARIANT"
fi

require_flake rebuild
cd "$flake"

# Jamais fatal : un échec de update garde l'état précédent.
if [[ "$UPDATE" -eq 1 ]]; then
    update_args=()
    [[ "$YES" -eq 1 ]] && update_args+=(--yes)
    UPDATE_FROM_REBUILD=1 "$here/update.sh" "${update_args[@]}" && rc=0 || rc=$?
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
    echo "Note: modified tracked files ${OK}ARE included${R} in the build; ${ERR}untracked files are NOT${R} (git add them first)."
    echo
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

# Le lock épingle `secrets` : sans `secrets sync`, un rebuild installerait l'ANCIENNE valeur.
if command -v secrets > /dev/null; then
    secrets_rc=0
    secrets status || secrets_rc=$?
    if [[ "$secrets_rc" -eq 2 ]]; then
        echo "${WARN}Modifications de secrets non déployables avant un pull du dépôt privé ; poursuite avec la révision épinglée.${R}"
    elif [[ "$secrets_rc" -ne 0 ]]; then
        echo "  Rebuild en l'état = ${ERR}déploiement de l'ANCIENNE valeur${R}."
        echo
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

# Des commits sur GitHub absents ici (changements de sites par apps.yml) : un rebuild en l'état
# les annulerait. Lecture en HTTPS, sans clé : le dépôt est public. Hors ligne, rien n'est vérifié.
branch=$(git symbolic-ref --quiet --short HEAD || true)
origin=$(git remote get-url origin 2> /dev/null | sed -E 's#^git@github\.com:#https://github.com/#')
if [[ -n "$branch" && "$origin" == https://* ]] \
    && timeout 15 git fetch --quiet "$origin" "$branch" 2> /dev/null; then
    behind=$(git rev-list --count HEAD..FETCH_HEAD)
    if [[ "$behind" -gt 0 ]]; then
        echo "${WARN}GitHub a $behind commit(s) sur $branch que ce dépôt n'a pas :${R}"
        git log --oneline HEAD..FETCH_HEAD | head -n 10
        echo "  Rebuild en l'état = ${ERR}retour en arrière de ces changements${R} (versions des sites comprises)."
        echo
        if [[ "$YES" -eq 1 ]]; then
            echo "${WARN}(--yes) Poursuite sans les récupérer.${R}"
        elif confirm "Les récupérer maintenant (git pull --rebase --autostash) ?" yes; then
            git pull --rebase --autostash "$origin" "$branch" || {
                err "git pull --rebase a échoué : résous-le, puis relance rebuild."
                exit 1
            }
        else
            echo "${WARN}Poursuite sans les récupérer.${R}"
        fi
    fi
fi

# Sites, appareils VPN, comptes Authelia, clés SSH : montrés et confirmés, même avec --yes.
access_review

echo "🚀 Starting NixOS system rebuild..."

PREV_SYSTEM="$(readlink -f /run/current-system)"

# Pas de --impure ni de --show-trace ; pour déboguer : REBUILD_EXTRA_ARGS=--show-trace.
read -ra EXTRA_ARGS <<< "${REBUILD_EXTRA_ARGS:-}"

# Jeton du dépôt privé `secrets` : nix.conf ne l'a qu'après activation (404 au premier rebuild).
# ATTENTION : si le répertoire n'est pas traversable, nix jette tout /etc/nix/nix.conf.
if sudo NIX_CONFIG='!include /var/lib/nix/access-tokens.conf' \
    nixos-rebuild switch --flake .#"$ATTR" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}; then
    echo "✅ System rebuild successful."

    NEW_SYSTEM="$(readlink -f /run/current-system)"
    if [[ "$PREV_SYSTEM" != "$NEW_SYSTEM" ]] && command -v nvd > /dev/null; then
        echo "📦 Changes since previous generation:"
        nvd diff "$PREV_SYSTEM" "$NEW_SYSTEM" || true
    fi

    if [ -n "${SWAYSOCK:-}" ]; then
        echo "💨 Sway session detected. Reloading configuration..."
        if swaymsg reload; then
            echo "🎉 Sway reloaded."
        else
            echo "⚠️  Sway reload échoué (le rebuild, lui, est bien appliqué)." >&2
        fi

        echo "📊 Restarting waybar..."
        systemctl --user try-restart waybar.service 2>/dev/null || true
    fi
else
    err "❌ System rebuild failed. Please check the errors above."
    exit 1
fi

if [[ "$YES" -eq 1 ]]; then
    hooks_offer "$PWD" --no-ask
else
    hooks_offer "$PWD"
fi

echo "All done."
