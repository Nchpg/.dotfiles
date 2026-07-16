#!/usr/bin/env bash

set -euo pipefail

HOST=""
PROFILE=""
VARIANT="dark"
UPDATE=0
YES=0

# Parsing simple des arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)    HOST="$2";    shift 2 ;;
        --profile) PROFILE="$2"; shift 2 ;;
        --variant) VARIANT="$2"; shift 2 ;;
        --update)  UPDATE=1;     shift ;;
        --yes)     YES=1;        shift ;;
        *) echo "Argument inconnu : $1" >&2; exit 1 ;;
    esac
done

# Vérification obligatoire
if [[ -z "$HOST" || -z "$PROFILE" ]]; then
    echo "Usage: $0 --host <host> --profile <profile> [--variant dark|light]" >&2
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
    # --yes : pas de confirmation (utilisé par `theme`, qui vient justement de
    # modifier un fichier tracké → le prompt serait systématique et inutile).
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

echo "🚀 Starting NixOS system rebuild..."

# Génération courante avant le switch, pour afficher le diff des paquets après.
PREV_SYSTEM="$(readlink -f /run/current-system)"

# Pas de --impure : la config est pure (aucun getEnv/lecture impure), et --impure
# désactiverait le cache d'évaluation -> chaque rebuild réévaluerait tout de zéro.
# Pas de --show-trace par défaut : il ralentit nettement l'éval. Pour déboguer une
# erreur d'éval, relancer ponctuellement via : REBUILD_EXTRA_ARGS=--show-trace rebuild
if sudo nixos-rebuild switch --flake .#"$ATTR" ${REBUILD_EXTRA_ARGS:-}; then
    echo "✅ System rebuild successful."

    # Diff des paquets ancien système → nouveau (versions bump, ajouts, retraits).
    NEW_SYSTEM="$(readlink -f /run/current-system)"
    if [[ "$PREV_SYSTEM" != "$NEW_SYSTEM" ]] && command -v nvd > /dev/null; then
        echo "📦 Changes since previous generation:"
        nvd diff "$PREV_SYSTEM" "$NEW_SYSTEM" || true
    fi

    if [ -n "${SWAYSOCK:-}" ]; then
        echo "💨 Sway session detected. Reloading configuration..."
        swaymsg reload
        echo "🎉 Sway reloaded."

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
