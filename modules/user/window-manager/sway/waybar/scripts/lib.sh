# shellcheck shell=bash

json_escape_to() { # $1 = nom de variable, $2 = valeur
    local -n _je_out=$1
    local s=$2
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    _je_out=$s
}

emit() {
    local _emit_t _emit_tt _emit_extra=""
    json_escape_to _emit_t "$1"
    json_escape_to _emit_tt "$2"
    [[ -n ${4:-} ]] && _emit_extra+=",\"alt\":\"$4\""
    [[ -n ${3:-} ]] && _emit_extra+=",\"class\":\"$3\""
    printf '{"text":"%s"%s,"tooltip":"%s"}\n' "$_emit_t" "$_emit_extra" "$_emit_tt"
}

find_battery() {
    local d
    for d in /sys/class/power_supply/BAT*; do
        if [[ -e $d/capacity ]]; then
            printf '%s' "$d"
            return 0
        fi
    done
    return 1
}

# Glyphes littéraux : printf '\U…' échoue sous LC_ALL=C
bat_icons=(󰂎 󰁺 󰁻 󰁼 󰁽 󰁾 󰁿 󰂀 󰂁 󰂂 󰁹)
bat_icon() { # $1 = pourcentage -> glyphe
    local idx=$(( ($1 + 5) / 10 ))
    (( idx < 0 )) && idx=0
    (( idx > 10 )) && idx=10
    printf '%s' "${bat_icons[idx]}"
}

weather_statedir() { printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/waybar"; }

weather_slug() { printf '%s' "${1//[^A-Za-z0-9]/_}"; }

weather_city() {
    local city
    city=$(cat "$(weather_statedir)/weather-city" 2>/dev/null) || true
    [[ -z "$city" ]] && city=$WEATHER_DEFAULT_CITY
    printf '%s' "$city"
}

weather_coords() { # $1 = ville
    local city=$1 statedir coordcache geo lat lon
    statedir=$(weather_statedir)
    coordcache="$statedir/weather-$(weather_slug "$city").coords"
    if [[ -s "$coordcache" ]]; then
        cat "$coordcache"
        return 0
    fi
    # || true : pas de réseau ne doit pas tuer l'appelant (set -e) avant le return 1
    geo=$(curl -fsS --max-time 8 -G "https://geocoding-api.open-meteo.com/v1/search" \
        --data-urlencode "name=${city}" \
        --data "count=1&language=fr&format=json" 2>/dev/null) || true
    read -r lat lon <<<"$(jq -r '.results[0] | "\(.latitude) \(.longitude)"' <<<"$geo" 2>/dev/null)"
    [[ -n "$lat" && "$lat" != "null" ]] || return 1
    mkdir -p "$statedir"
    printf '%s %s' "$lat" "$lon" >"$coordcache"
    printf '%s %s' "$lat" "$lon"
}
