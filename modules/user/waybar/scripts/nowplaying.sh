#!/usr/bin/env bash
# Morceau Spotify en cours (MPRIS/playerctl). Sortie vide si Spotify est fermé
# -> waybar masque le module. Logique reprise telle quelle de sway-bar.sh.

command -v playerctl &>/dev/null || exit 0

status=$(playerctl -p spotify status 2>/dev/null)
[[ -z "$status" ]] && exit 0

case "$status" in
    Playing) icon="󰐊" ;;
    Paused)  icon="󰏤" ;;
    *)       icon="󰓛" ;;
esac

meta=$(playerctl -p spotify metadata --format '{{ artist }} - {{ title }}' 2>/dev/null)
# Repli si pas d'artiste (podcast, pub, etc.) -> juste le titre.
[[ -z "$meta" || "$meta" == " - "* ]] && \
    meta=$(playerctl -p spotify metadata --format '{{ title }}' 2>/dev/null)
[[ -z "$meta" ]] && exit 0

MAX_NP_LENGTH=35
if [[ ${#meta} -gt $MAX_NP_LENGTH ]]; then
    meta="${meta:0:$MAX_NP_LENGTH}…"
fi

echo "$icon   $meta"
