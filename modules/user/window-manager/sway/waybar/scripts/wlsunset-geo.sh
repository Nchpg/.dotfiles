#!/usr/bin/env bash
set -euo pipefail
# Lancé par le service systemd wlsunset (cf. default.nix). Récupère la ville
# météo courante et SES coordonnées (cache partagé avec weather.sh via lib.sh),
# pour que le night light suive le même lieu que la météo. Repli sur
# NIGHTLIGHT_FALLBACK_LAT/LON (option nightlight.fallbackCoords) si la ville
# n'a jamais pu être géocodée. `exec` : wlsunset remplace ce process, donc
# systemd suit directement le démon.
export LC_ALL=C

read -r lat lon <<<"$(weather_coords "$(weather_city)")"
[[ -z "$lat" ]] && { lat=$NIGHTLIGHT_FALLBACK_LAT; lon=$NIGHTLIGHT_FALLBACK_LON; }

exec wlsunset -l "$lat" -L "$lon" -t 3800 -T 6500
