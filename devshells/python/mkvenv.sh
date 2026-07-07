#!/usr/bin/env bash

# uv choisit le python : --python X.Y explicite, .python-version du projet,
# sinon le python nix du devshell. Les interpréteurs manquants sont
# téléchargés par uv (cache ~/.cache/uv partagé entre projets).
uv venv "$@"

# Dernier argument positionnel = nom du venv (défaut uv : .venv)
VENV=".venv"
for arg in "$@"; do
  case "$arg" in -*) ;; *) VENV="$arg" ;; esac
done

case "${SH:-$(basename "${SHELL:-bash}")}" in
  fish) ACTIVATE="activate.fish" ;;
  *) ACTIVATE="activate" ;;
esac
echo "✔️ venv créé (uv). Activation : source $VENV/bin/$ACTIVATE"
