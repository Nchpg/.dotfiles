#!/usr/bin/env bash
set -euo pipefail

statedir=$(weather_statedir)
mkdir -p "$statedir"
printf '%s' "$1" >"$statedir/weather-city"
pkill -RTMIN+"$WAYBAR_WEATHER_SIGNAL" waybar || true
systemctl --user try-restart wlsunset
