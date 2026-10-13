#!/usr/bin/env bash

set -euo pipefail

HOST=""
PROFILE=""
VARIANT="dark"
UPDATE=0
YES=0

# Parsing simple des arguments.
# need_value : sous `set -u`, un `--host` sans valeur mourait sur un
# « $2: unbound variable » au lieu du message d'usage juste en dessous.
need_value() {
    [[ $# -ge 2 ]] || { echo "Option $1 : valeur manquante" >&2; exit 1; }
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)    need_value "$@"; HOST="$2";    shift 2 ;;
        --profile) need_value "$@"; PROFILE="$2"; shift 2 ;;
        --variant) need_value "$@"; VARIANT="$2"; shift 2 ;;
        --update)  UPDATE=1;     shift ;;
        --yes)     YES=1;        shift ;;
        *) echo "Argument inconnu : $1" >&2; exit 1 ;;
    esac
done

# Vérification obligatoire
if [[ -z "$HOST" || -z "$PROFILE" ]]; then
    echo "Usage: $0 --host <host> --profile <profile> [--variant dark|light] [--update] [--yes]" >&2
    echo "  --update : lance update.sh (modules à update.sh + inputs du flake, au choix)" >&2
    echo "  --yes    : pas de confirmation (working tree sale, ni bump de module) ;" >&2
    echo "             le lock des secrets n'est alors jamais modifié (avertissement seul)" >&2
    exit 1
fi

case "$VARIANT" in
    dark|light) ;;
    *) echo "Variante invalide : $VARIANT (attendu : dark ou light)" >&2; exit 1 ;;
esac

# Nom de la cible du flake : la variante dark garde le nom historique
# (personal-gram), light suffixe (personal-gram-light) — cf. flake.nix.
ATTR="$PROFILE-$HOST"
if [[ "$VARIANT" != "dark" ]]; then
    ATTR="$ATTR-$VARIANT"
fi

YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

cd "$(dirname "$0")/.."

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
    echo -e "${RED}Error: Not a Git repository. Cannot check for uncommitted changes.${NC}" >&2
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo -e "${YELLOW}Warning: uncommitted changes or untracked files in the working tree.${NC}"
    echo "------------------------------------------------------------------"
    git status --short
    echo "------------------------------------------------------------------"
    # Rappel du comportement flake : les modifs des fichiers TRACKÉS sont bien
    # incluses même non commitées ; seuls les fichiers NON TRACKÉS sont ignorés.
    echo -e "Note: modified tracked files ${GREEN}ARE included${NC} in the build; ${RED}untracked files are NOT${NC} (git add them first)."
    echo
    # --yes : pas de confirmation (utilisé par genclean pour son rebuild final
    # automatique ; `theme` ne modifie plus aucun fichier depuis que la
    # variante est portée par la cible du flake).
    if [[ "$YES" -eq 1 ]]; then
        echo "(--yes) Continuing without confirmation."
    else
        read -p "Continue anyway? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${RED}Rebuild aborted by user.${NC}"
            exit 1
        fi
    fi
else
    echo -e "${GREEN}✅ Git status is clean.${NC}"
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
        echo -e "${YELLOW}Modifications de secrets non déployables avant un pull du dépôt privé ; poursuite avec la révision épinglée.${NC}"
    elif [[ "$secrets_rc" -ne 0 ]]; then
        echo -e "  Rebuild en l'état = ${RED}déploiement de l'ANCIENNE valeur${NC}."
        echo
        # --yes (genclean) ne bouge JAMAIS ce lock : une maintenance
        # de générations n'a pas à déployer de nouvelles valeurs de secrets
        # sans qu'on l'ait demandé. Avertissement seul, révision épinglée.
        if [[ "$YES" -eq 1 ]]; then
            echo -e "${YELLOW}(--yes) Lock non modifié, poursuite avec la révision épinglée.${NC}"
            echo "  Pour déployer la nouvelle : \`secrets sync\`, ou rebuild sans --yes."
        else
            read -p "Synchroniser maintenant (secrets sync) ? [Y/n] " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                secrets sync || {
                    echo -e "${RED}Synchronisation des secrets échouée.${NC}" >&2
                    exit 1
                }
            else
                echo -e "${YELLOW}Poursuite avec la révision épinglée.${NC}"
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
    echo -e "${RED}❌ System rebuild failed. Please check the errors above.${NC}" >&2
    exit 1
fi

# ── Hooks git du dépôt ───────────────────────────────────────────────────────
#
# Ce sont eux qui tiennent le dépôt de secrets en phase au pull et au push
# (cf. .githooks et `secrets git-hook`). Actifs seulement si ce clone le
# demande (core.hooksPath, réglage local jamais poussé) : un clone fait sans
# ./init.sh les a éteints. Après un rebuild, la commande `secrets` qu'ils
# appellent est à jour : c'est le bon moment pour le rattraper.
#
# --yes ne décide pas à ta place : avertissement seul.
if [ -d .githooks ] && [ "$(git config --get core.hooksPath || true)" != .githooks ]; then
    echo -e "${YELLOW}⚠ Hooks git inactifs dans $PWD : secrets non synchronisés au pull/push.${NC}"
    if [[ "$YES" -eq 1 ]] || [ ! -t 0 ]; then
        echo "  Pour les activer : git -C $PWD config core.hooksPath .githooks"
    else
        read -p "Les activer maintenant ? [Y/n] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            git config core.hooksPath .githooks
            echo -e "${GREEN}✓ Hooks git actifs.${NC}"
        fi
    fi
fi

echo "All done."
