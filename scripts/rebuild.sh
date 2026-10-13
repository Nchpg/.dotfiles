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
# déployée tant qu'un `nix flake update secrets` n'a pas bougé le lock ici. C'est
# voulu — sans ça, éditer le dépôt privé suffirait à changer ce que les machines
# déploient. Mais la contrepartie est un rebuild qui réussit en installant
# l'ANCIENNE valeur, sans un message.
#
# Ça a coûté une base Authelia illisible, un tunnel Cloudflare hors service et
# deux clés WireGuard désynchronisées en une soirée. On compare donc, ici, au
# moment qui compte.
#
# Comparaison au HEAD LOCAL, sans réseau : toute opération sur le dépôt privé
# passe par SSH et redemanderait la phrase de passe à chaque rebuild. Le cas
# « une autre machine a poussé » est couvert ailleurs, par le pull que la
# commande `secrets` fait avant chaque édition.
SECRETS_STORE="${MY_SECRETS:-$HOME/.secrets}"
if [ -d "$SECRETS_STORE/.git" ] && [ -f flake.lock ]; then
    SECRETS_HEAD="$(git -C "$SECRETS_STORE" rev-parse HEAD 2> /dev/null || true)"
    # jq sur la structure du lock ; grep en repli (jq absent du PATH).
    SECRETS_LOCKED="$(jq -r '.nodes.secrets.locked.rev // empty' flake.lock 2> /dev/null \
        || grep -A 12 '"secrets": {' flake.lock | grep -m1 '"rev"' | cut -d'"' -f4 || true)"

    if [ -n "$SECRETS_HEAD" ] && [ -n "$SECRETS_LOCKED" ] && [ "$SECRETS_HEAD" != "$SECRETS_LOCKED" ]; then
        echo -e "${YELLOW}Le lock ne pointe pas sur ton dernier commit de secrets.${NC}"
        echo "  dépôt : $SECRETS_HEAD"
        echo "  lock  : $SECRETS_LOCKED"
        echo -e "  Rebuild en l'état = ${RED}déploiement de l'ANCIENNE valeur${NC}."
        echo
        # --yes (genclean, theme...) ne bouge JAMAIS ce lock : une maintenance
        # de générations n'a pas à déployer de nouvelles valeurs de secrets
        # sans qu'on l'ait demandé. Avertissement seul, révision épinglée.
        if [[ "$YES" -eq 1 ]]; then
            echo -e "${YELLOW}(--yes) Lock non modifié, poursuite avec la révision épinglée.${NC}"
            echo "  Pour déployer la nouvelle : \`secrets sync\`, ou rebuild sans --yes."
            REPLY=n
        else
            read -p "Mettre le lock à jour maintenant ? [Y/n] " -n 1 -r
            echo
        fi
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            # Mêmes précautions que `secrets sync` (modules/system/commands/secrets) :
            #  - sudo : le jeton de lecture du dépôt privé est en 0600 root, et
            #    la récupération d'une entrée se fait dans l'évaluateur ;
            #  - NIX_CONFIG : ce jeton, même sur une machine neuve dont
            #    /etc/nix/nix.conf ne l'inclut pas encore (cf. plus bas) ;
            #  - safe.directory : root opère sur un dépôt qui t'appartient ;
            #  - --refresh : sans lui Nix resert une résolution vieille d'une heure ;
            #  - propriétaire de flake.lock restauré (réécrit par root).
            lock_owner="$(stat -c '%u:%g' flake.lock)"
            sudo env \
                NIX_CONFIG='!include /var/lib/nix/access-tokens.conf' \
                GIT_CONFIG_COUNT=1 \
                GIT_CONFIG_KEY_0=safe.directory \
                GIT_CONFIG_VALUE_0="$PWD" \
                nix flake update secrets --refresh --flake "$PWD" || {
                echo -e "${RED}Mise à jour du lock échouée.${NC}" >&2
                exit 1
            }
            if [ "$(stat -c '%u:%g' flake.lock)" != "$lock_owner" ]; then
                sudo chown -h "$lock_owner" -- flake.lock
            fi
            # Le lock pointe-t-il VRAIMENT sur le commit local ? Il prend le HEAD
            # distant : des commits non poussés dans le dépôt privé passeraient
            # sinon sans un mot, et le rebuild déploierait l'ancienne valeur.
            SECRETS_LOCKED="$(jq -r '.nodes.secrets.locked.rev // empty' flake.lock 2> /dev/null \
                || grep -A 12 '"secrets": {' flake.lock | grep -m1 '"rev"' | cut -d'"' -f4 || true)"
            if [ "$SECRETS_LOCKED" != "$SECRETS_HEAD" ]; then
                echo -e "${RED}Le lock pointe sur $SECRETS_LOCKED, pas sur ton commit local $SECRETS_HEAD.${NC}" >&2
                echo "  Commits de secrets non poussés ? \`git -C $SECRETS_STORE push\`, puis relance." >&2
                exit 1
            fi
        elif [[ "$YES" -ne 1 ]]; then
            echo -e "${YELLOW}Poursuite avec la révision épinglée.${NC}"
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

echo "All done."
