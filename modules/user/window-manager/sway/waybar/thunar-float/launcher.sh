# shellcheck shell=bash
# (Pas de shebang : writeShellApplication l'ajoute, avec set -euo pipefail.)
#
# Clic sur la case disque de waybar : signale au démon (daemon.sh) que la
# PROCHAINE fenêtre Thunar est l'éphémère (flottante, Échap, fermée à
# l'ouverture d'un fichier), puis ouvre Thunar.
dir="${XDG_RUNTIME_DIR:-/tmp}/thunar-float"
mkdir -p "$dir"
touch "$dir/pending"

# Placée AVANT l'apparition de la fenêtre : sway l'applique dès la première
# image, donc ni passage en tuile plein écran ni redimensionnements visibles
# (ce que faisait le démon seul, en corrigeant après coup). `exec` garde ce
# PID à Thunar, d'où le critère pid=$$. Sans effet si un Thunar tourne déjà
# (la fenêtre appartient alors à CE processus-là) : le démon prend le relais.
# Règle d'exécution, oubliée au prochain rechargement de sway.
swaymsg -q "for_window [app_id=\"thunar\" pid=$$] floating enable, resize set 1200 750, move position center" || true

exec thunar "$@"
