#!/usr/bin/env bash

set -e

./private-switch.sh rebuild

YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

cd "$(dirname "$0")"

echo "🔎 Checking Git status before rebuild..."

if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo -e "${RED}Error: Not a Git repository. Cannot check for uncommitted changes.${NC}"
    exit 1
fi

GIT_STATUS=$(git status --porcelain)

if [ -n "$GIT_STATUS" ]; then
    echo -e "${YELLOW}Warning: Your Git working directory has uncommitted changes or untracked files.${NC}"
    echo "------------------------------------------------------------------"
    git status
    echo "------------------------------------------------------------------"
    echo -e "These changes ${RED}will NOT be included${NC} in the build unless you commit them."
    echo -e "Nix will build from the state of your last commit."
    echo
    read -p "Do you want to use impure switch " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${RED}Rebuild aborted by user.${NC}"
        exit 1
    fi
    echo -e "${GREEN}Proceeding with impure rebuild...${NC}"
else
    echo -e "${GREEN}✅ Git status is clean. Proceeding with rebuild...${NC}"
fi

echo "🚀 Starting NixOS system rebuild..."

sudo nixos-rebuild switch --flake .#personal.gram --impure --show-trace

if [ $? -eq 0 ]; then
    echo "✅ System rebuild successful."

    if [ -n "$SWAYSOCK" ]; then
        echo "💨 Sway session detected. Reloading configuration..."
        swaymsg reload
        echo "🎉 Sway reloaded."
    fi
else
    echo "❌ System rebuild failed. Please check the errors above."
fi

echo "All done."
