#!/usr/bin/env bash

# Serveur JupyterLab via uvx : installé une fois dans le cache uv partagé,
# sans polluer le venv du projet. Racine épinglée sur le dossier de
# lancement (insensible à une config ~/.jupyter). Ouvre l'URL avec token
# affichée par CE serveur — un vieux localhost:8888 en favori peut pointer
# sur un autre serveur rooté ailleurs.
echo "📂 Racine JupyterLab : $PWD"
exec uvx --from jupyterlab jupyter-lab --ServerApp.root_dir="$PWD" "$@"
