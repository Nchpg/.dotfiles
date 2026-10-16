#!/usr/bin/env bash
set -euo pipefail

MAX_NP_LENGTH=35
SEP=$'\x1f' # ne peut pas apparaître dans les métadonnées

playerctl -p spotify --follow \
    --format "{{status}}${SEP}{{artist}}${SEP}{{title}}" metadata 2>/dev/null \
| while IFS="$SEP" read -r status artist title; do
    if [[ -z "$status" ]]; then
        echo
        continue
    fi

    case "$status" in
        Playing) icon="󰐊" ;;
        Paused)  icon="󰏤" ;;
        *)       icon="󰓛" ;;
    esac

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
