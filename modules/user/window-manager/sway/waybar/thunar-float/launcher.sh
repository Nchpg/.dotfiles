# shellcheck shell=bash
# (Pas de shebang : writeShellApplication l'ajoute, avec set -euo pipefail.)
#
# Clic sur la case disque de waybar : signale au démon (daemon.sh) que la
# PROCHAINE fenêtre Thunar est l'éphémère (flottante, Échap/q, fermée à
# l'ouverture d'un fichier), puis ouvre Thunar.
dir="${XDG_RUNTIME_DIR:-/tmp}/thunar-float"
mkdir -p "$dir"
touch "$dir/pending"
exec thunar "$@"
