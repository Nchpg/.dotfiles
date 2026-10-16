# shellcheck shell=bash
dir="${XDG_RUNTIME_DIR:-/tmp}/thunar-float"
mkdir -p "$dir"
touch "$dir/pending"

# `exec` garde ce PID à Thunar (pid=$$). Sans effet si un Thunar tourne déjà.
swaymsg -q "for_window [app_id=\"thunar\" pid=$$] floating enable, resize set 1200 750, move position center" || true

exec thunar "$@"
