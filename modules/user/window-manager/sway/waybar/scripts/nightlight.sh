#!/usr/bin/env bash
set -euo pipefail
# nightlight.sh toggle|allowed — night light (service wlsunset, cf.
# ../nightlight.nix).
#
# Le choix PERSISTE au reboot via un drapeau : couper le pose, rallumer le
# retire. `allowed` sert d'ExecCondition au service (sans drapeau, WantedBy
# graphical-session relancerait systématiquement le service) : code 1 ->
# « skipped », pas « failed ». Seule définition du chemin du drapeau.
# WAYBAR_BACKLIGHT_SIGNAL : posé par scripts.nix (l'icône de la case
# luminosité reflète l'état du night light).

flag="${XDG_STATE_HOME:-$HOME/.local/state}/wlsunset-off"

case "${1:-}" in
    allowed)
        [ ! -e "$flag" ]
        ;;
    toggle)
        if systemctl --user is-active --quiet wlsunset; then
            systemctl --user stop wlsunset
            mkdir -p "$(dirname "$flag")"
            touch "$flag"
        else
            rm -f "$flag"
            systemctl --user start wlsunset
        fi
        pkill -RTMIN+"$WAYBAR_BACKLIGHT_SIGNAL" waybar || true
        ;;
    *)
        echo "usage: nightlight.sh toggle|allowed" >&2
        exit 1
        ;;
esac
