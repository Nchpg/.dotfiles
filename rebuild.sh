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
    echo "  --update : bump l'input claude-code + les modules à update.sh (confirmation par module)" >&2
    echo "  --yes    : pas de confirmation (working tree sale, ni bump de module)" >&2
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

cd "$(dirname "$0")"

# Bump claude-code seulement sur demande (--update / rebuild -u) : le faire à
# chaque rebuild salissait flake.lock (→ warning git systématique) et
# re-téléchargeait claude-code inutilement.
if [[ "$UPDATE" -eq 1 ]]; then
    echo "⬆️  Updating claude-code flake input to latest..."
    # Non bloquant : si offline / rate-limit, on garde la version déjà lockée.
    nix flake update claude-code || echo "⚠️  bump claude-code ignoré (offline/rate-limit) — version lockée conservée."

    # Auto-discovery : tout module qui veut être bumpé par `rebuild -u` place un
    # `update.sh` (nom exact) à sa racine — pas de liste à tenir à jour ici.
    # Même mécanisme côté CI, cf. update.yml. Chaque échec reste local au
    # module (offline, API tierce down, ...), jamais fatal pour les autres.
    # Chargé dans un tableau (pas de `while read < <(find ...)`) : sinon le
    # `read -p` de confirmation ci-dessous lirait le flux de `find` au lieu du
    # terminal, et sauterait silencieusement toutes les mises à jour.
    # Pas de -maxdepth : il valait 4 et sautait silencieusement
    # dev/vercel-cli/claude-plugin/update.sh (un cran plus profond). Borner la
    # profondeur couple ce script à l'arborescence des modules — un déplacement
    # de dossier désactive une mise à jour sans le moindre message.
    mapfile -d '' -t update_scripts < <(find modules -name update.sh -print0 | sort -z)
    for script in "${update_scripts[@]}"; do
        module_dir="$(dirname "$script")"

        # Contrairement à la CI (protégée par une PR à relire avant merge), un
        # `rebuild -u` local enchaîne directement sur `nixos-rebuild switch` :
        # sans ce garde-fou, une version fraîchement publiée (donc jamais
        # auditée) s'appliquerait sur la machine sans confirmation. --yes
        # (genclean) saute la question, comme pour le git status plus bas.
        if [[ "$YES" -ne 1 ]]; then
            read -p "Mettre à jour ce module ($module_dir) ? [y/N] " -n 1 -r
            echo
            [[ $REPLY =~ ^[Yy]$ ]] || continue
        fi

        echo "⬆️  Running $script..."
        MY_FLAKE="$PWD" "$script" || echo "⚠️  $script ignoré (échec) — état précédent conservé."
    done
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
    SECRETS_LOCKED="$(grep -A 12 '"secrets": {' flake.lock | grep -m1 '"rev"' | cut -d'"' -f4 || true)"

    if [ -n "$SECRETS_HEAD" ] && [ -n "$SECRETS_LOCKED" ] && [ "$SECRETS_HEAD" != "$SECRETS_LOCKED" ]; then
        echo -e "${YELLOW}Le lock ne pointe pas sur ton dernier commit de secrets.${NC}"
        echo "  dépôt : $SECRETS_HEAD"
        echo "  lock  : $SECRETS_LOCKED"
        echo -e "  Rebuild en l'état = ${RED}déploiement de l'ANCIENNE valeur${NC}."
        echo
        if [[ "$YES" -eq 1 ]]; then
            echo "(--yes) Mise à jour du lock."
            REPLY=y
        else
            read -p "Mettre le lock à jour maintenant ? [Y/n] " -n 1 -r
            echo
        fi
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            # sudo : le jeton de lecture du dépôt privé est en 0600 root, et la
            # récupération d'une entrée se fait dans l'évaluateur.
            # --refresh : sans lui Nix resert une résolution vieille d'une heure.
            sudo nix flake update secrets --refresh || {
                echo -e "${RED}Mise à jour du lock échouée.${NC}" >&2
                exit 1
            }
        else
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
