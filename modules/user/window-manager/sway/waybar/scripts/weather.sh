#!/usr/bin/env bash
set -euo pipefail
# Open-Meteo plutôt que wttr.in, dont le ressenti est faux en air sec.

export LC_ALL=C

statedir=$(weather_statedir)
mkdir -p "$statedir"

location=$(weather_city)
cache="$statedir/weather-$(weather_slug "$location").json"
read -r lat lon <<<"$(weather_coords "$location")"

# Initialisé : sous `set -u`, $json serait unbound si lat est vide
json=""
if [[ -n "$lat" && "$lat" != "null" ]]; then
    # || true : pas de réseau, repli sur le cache
    json=$(curl -fsS --max-time 8 -G "https://api.open-meteo.com/v1/forecast" \
        --data-urlencode "latitude=${lat}" \
        --data-urlencode "longitude=${lon}" \
        --data "current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,wind_direction_10m,is_day&timezone=auto" \
        2>/dev/null) || true
fi
if [[ -n "$json" ]] && jq -e .current >/dev/null 2>&1 <<<"$json"; then
    printf '%s' "$json" >"$cache"
else
    json=$(cat "$cache" 2>/dev/null) || true
fi

if [[ -z "$json" ]] || ! jq -e .current >/dev/null 2>&1 <<<"$json"; then
    emit "--" "Météo indisponible" "" offline
    exit 0
fi

read -r temp feels code humidity wind winddeg isday <<<"$(
    jq -r '.current
        | "\(.temperature_2m) \(.apparent_temperature) \(.weather_code) \(.relative_humidity_2m) \(.wind_speed_10m) \(.wind_direction_10m) \(.is_day)"' \
        <<<"$json"
)"

temp=$(printf '%.0f' "$temp")
feels=$(printf '%.0f' "$feels")
wind=$(printf '%.0f' "$wind")
humidity=$(printf '%.0f' "$humidity")

deg=$(printf '%.0f' "$winddeg")
dirs=(N NNE NE ENE E ESE SE SSE S SSO SO OSO O ONO NO NNO)
winddir=${dirs[$(((deg * 100 + 1125) / 2250 % 16))]}

case "$code" in
    0)  wcat=$([[ $isday == 1 ]] && echo clear-day || echo clear-night);  desc="Ciel dégagé" ;;
    1)  wcat=$([[ $isday == 1 ]] && echo clear-day || echo clear-night);  desc="Plutôt dégagé" ;;
    2)  wcat=$([[ $isday == 1 ]] && echo partly-day || echo partly-night); desc="Partiellement nuageux" ;;
    3)  wcat=cloudy;     desc="Couvert" ;;
    45)  wcat=fog;        desc="Brouillard" ;;
    48)  wcat=fog;        desc="Brouillard givrant" ;;
    51)  wcat=rain-light; desc="Bruine légère" ;;
    53)  wcat=rain-light; desc="Bruine modérée" ;;
    55)  wcat=rain-light; desc="Bruine dense" ;;
    56)  wcat=sleet;      desc="Bruine verglaçante légère" ;;
    57)  wcat=sleet;      desc="Bruine verglaçante dense" ;;
    61)  wcat=rain-light; desc="Pluie faible" ;;
    63)  wcat=rain;       desc="Pluie modérée" ;;
    65)  wcat=rain;       desc="Pluie forte" ;;
    66)  wcat=sleet;      desc="Pluie verglaçante faible" ;;
    67)  wcat=sleet;      desc="Pluie verglaçante forte" ;;
    71)  wcat=snow;       desc="Neige faible" ;;
    73)  wcat=snow;       desc="Neige modérée" ;;
    75)  wcat=snow-heavy; desc="Neige forte" ;;
    77)  wcat=snow;       desc="Grains de neige" ;;
    80)  wcat=rain-light; desc="Averses faibles" ;;
    81)  wcat=rain;       desc="Averses modérées" ;;
    82)  wcat=rain;       desc="Averses violentes" ;;
    85)  wcat=snow;       desc="Averses de neige faibles" ;;
    86)  wcat=snow-heavy; desc="Averses de neige fortes" ;;
    95)  wcat=thunder;    desc="Orage" ;;
    96)  wcat=thunder;    desc="Orage, grêle légère" ;;
    99)  wcat=thunder;    desc="Orage, grêle forte" ;;
    *)  wcat=cloudy;     desc="Conditions inconnues" ;;
esac

case "$wcat" in
    clear-*) class=sunny ;;
    cloudy | fog) class=cloudy ;;
    rain* | sleet | snow* | hail | thunder) class=rain ;;
    *) class=default ;;
esac

text="${temp}°"
updated=$(date -r "$cache" '+%d/%m %H:%M' 2>/dev/null) || true
tooltip="${location} · ${desc}"
tooltip+=$'\n'"Ressenti ${feels}°  ·  Humidité ${humidity}%"
tooltip+=$'\n'"Vent ${wind} km/h ${winddir}"
[[ -n "$updated" ]] && tooltip+=$'\n'"Maj ${updated}"

emit "$text" "$tooltip" "$class" "$wcat"
