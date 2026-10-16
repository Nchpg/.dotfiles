#!/usr/bin/env bash
set -euo pipefail

echo "📂 Racine JupyterLab : $PWD"
exec uvx --from jupyterlab jupyter-lab --ServerApp.root_dir="$PWD" "$@"
