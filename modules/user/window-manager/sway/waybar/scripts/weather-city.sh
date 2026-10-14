#!/usr/bin/env bash
set -euo pipefail
# weather-city.sh VILLE : action du menu clic droit du module météo. Écrit la
# ville (lue par weather_city, lib.sh), réveille la météo, et relance le night
# light s'il tourne (no-op sinon) pour qu'il adopte les coords de la nouvelle
# ville. WAYBAR_WEATHER_SIGNAL : posé par scripts.nix.

statedir=$(weather_statedir)
mkdir -p "$statedir"
printf '%s' "$1" >"$statedir/weather-city"
pkill -RTMIN+"$WAYBAR_WEATHER_SIGNAL" waybar || true
systemctl --user try-restart wlsunset
