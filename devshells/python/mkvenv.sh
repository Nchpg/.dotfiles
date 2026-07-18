#!/usr/bin/env bash

# uv choisit le python : --python X.Y explicite, .python-version du projet,
# sinon le python nix du devshell. Les interpréteurs manquants sont
# téléchargés par uv (cache ~/.cache/uv partagé entre projets).
#
# On ne devine pas le chemin du venv depuis les arguments (des options comme
# --prompt/--cache-dir prennent une valeur sans tiret et cassaient
# l'heuristique) : on retrouve le pyvenv.cfg réellement créé après coup.
MARKER="$(mktemp)"
uv venv "$@"
VENV="$(find . -maxdepth 2 -name pyvenv.cfg -newer "$MARKER" -print -quit | xargs -r dirname)"
rm -f "$MARKER"
VENV="${VENV:-.venv}"

case "${SH:-$(basename "${SHELL:-bash}")}" in
  fish) ACTIVATE="activate.fish" ;;
  *) ACTIVATE="activate" ;;
esac
echo "✔️ venv créé (uv). Activation : source $VENV/bin/$ACTIVATE"
