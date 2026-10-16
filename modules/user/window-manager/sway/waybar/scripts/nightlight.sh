#!/usr/bin/env bash
set -euo pipefail

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
