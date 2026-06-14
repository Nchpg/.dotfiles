#!/usr/bin/env bash

set -euo pipefail

HOST=""
PROFILE=""

# Parsing simple des arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)    HOST="$2";    shift 2 ;;
        --profile) PROFILE="$2"; shift 2 ;;
        *) echo "Argument inconnu : $1" >&2; exit 1 ;;
    esac
done

# Vérification obligatoire
if [[ -z "$HOST" || -z "$PROFILE" ]]; then
    echo "Usage: $0 --host <host> --profile <profile>" >&2
    exit 1
fi

YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

cd "$(dirname "$0")"

echo "⬆️  Updating claude-code flake input to latest..."
# Non bloquant : si offline / rate-limit, on garde la version déjà lockée.
nix flake update claude-code || echo "⚠️  bump claude-code ignoré (offline/rate-limit) — version lockée conservée."

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
    echo -e "Nix builds from your last commit: these changes ${RED}will NOT be included${NC} unless committed."
    echo
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${RED}Rebuild aborted by user.${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}✅ Git status is clean.${NC}"
fi

echo "🚀 Starting NixOS system rebuild..."

# Pas de --impure : la config est pure (aucun getEnv/lecture impure), et --impure
# désactiverait le cache d'évaluation -> chaque rebuild réévaluerait tout de zéro.
# Pas de --show-trace par défaut : il ralentit nettement l'éval. Pour déboguer une
# erreur d'éval, relancer ponctuellement via : REBUILD_EXTRA_ARGS=--show-trace rebuild
if sudo nixos-rebuild switch --flake .#"$PROFILE"-"$HOST" ${REBUILD_EXTRA_ARGS:-}; then
    echo "✅ System rebuild successful."

    if [ -n "${SWAYSOCK:-}" ]; then
        echo "💨 Sway session detected. Reloading configuration..."
        swaymsg reload
        echo "🎉 Sway reloaded."
    fi
else
    echo -e "${RED}❌ System rebuild failed. Please check the errors above.${NC}" >&2
    exit 1
fi

echo "All done."
