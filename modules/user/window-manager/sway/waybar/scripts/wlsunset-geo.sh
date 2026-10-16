#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

read -r lat lon <<<"$(weather_coords "$(weather_city)")"
[[ -z "$lat" ]] && { lat=$NIGHTLIGHT_FALLBACK_LAT; lon=$NIGHTLIGHT_FALLBACK_LON; }

exec wlsunset -l "$lat" -L "$lon" -t 3800 -T 6500
