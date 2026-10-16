#!/usr/bin/env bash
set -euo pipefail

MARKER="$(mktemp)"
trap 'rm -f "$MARKER"' EXIT
uv venv "$@"
VENV="$(find . -maxdepth 2 -name pyvenv.cfg -newer "$MARKER" -print0 -quit | xargs -r0 dirname)"
VENV="${VENV:-.venv}"

case "${SH:-$(basename "${SHELL:-bash}")}" in
  fish) ACTIVATE="activate.fish" ;;
  *) ACTIVATE="activate" ;;
esac
echo "✔️ venv créé (uv). Activation : source $VENV/bin/$ACTIVATE"
