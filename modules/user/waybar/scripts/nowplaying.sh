#!/usr/bin/env bash
# Morceau Spotify en cours (MPRIS/playerctl), piloté par ÉVÉNEMENTS via
# `playerctl --follow` plutôt que par polling : mise à jour instantanée au
# changement de piste, play/pause, etc. (--follow réémet à chaque
# PropertiesChanged du player, qui couvre métadonnées ET statut de lecture).
#
# Le script tourne en continu (module waybar sans `interval`, avec
# `restart-interval` pour le relancer s'il s'arrête). Une ligne vide masque le
# module (Spotify fermé / stoppé).

command -v playerctl &>/dev/null || exit 0

MAX_NP_LENGTH=35
SEP=$'\x1f' # unit separator : ne peut pas apparaître dans les métadonnées.

playerctl -p spotify --follow \
    --format "{{status}}${SEP}{{artist}}${SEP}{{title}}" metadata 2>/dev/null \
| while IFS="$SEP" read -r status artist title; do
    if [[ -z "$status" ]]; then
        echo # plus de player / piste -> module masqué
        continue
    fi

    case "$status" in
        Playing) icon="󰐊" ;;
        Paused)  icon="󰏤" ;;
        *)       icon="󰓛" ;;
    esac

    # Repli si pas d'artiste (podcast, pub, etc.) -> juste le titre.
    if [[ -n "$artist" && -n "$title" ]]; then
        meta="$artist - $title"
    else
        meta="$title"
    fi
    [[ -z "$meta" ]] && { echo; continue; }

    if [[ ${#meta} -gt $MAX_NP_LENGTH ]]; then
        meta="${meta:0:$MAX_NP_LENGTH}…"
    fi

    echo "$icon   $meta"
done
