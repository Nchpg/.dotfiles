# shellcheck shell=bash
# Helpers partagés par les scripts des modules custom waybar. Ce fichier n'a
# pas de shebang : il est inliné EN TÊTE de chaque script au build (cf.
# ../scripts.nix), avant le corps du script. Aussi inliné par l'alerte
# batterie (sway/notifications), pour find_battery.
#
# json_escape_to : échappe une valeur pour l'insérer dans un champ JSON
# (backslash, guillemet, et vraies nouvelles lignes -> \n pour les tooltips
# multi-lignes), écrite dans la variable nommée $1 -> pas de sous-shell $(...),
# donc pas de fork. Les scripts construisent donc leurs tooltips avec de
# VRAIES nouvelles lignes ($'\n'), pas des "\n" littéraux.
json_escape_to() { # $1 = nom de variable, $2 = valeur
    local -n _je_out=$1
    local s=$2
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    _je_out=$s
}

# emit TEXTE TOOLTIP [CLASSE] [ALT] : LA sortie JSON des modules custom.
# Texte et tooltip échappés (le tooltip peut être vide) ; classe CSS (couleur)
# et alt (clé de format-icons côté Nix) omises si vides. Sans sous-shell :
# appelée en boucle par resources.sh.
emit() {
    local _emit_t _emit_tt _emit_extra=""
    json_escape_to _emit_t "$1"
    json_escape_to _emit_tt "$2"
    [[ -n ${4:-} ]] && _emit_extra+=",\"alt\":\"$4\""
    [[ -n ${3:-} ]] && _emit_extra+=",\"class\":\"$3\""
    printf '{"text":"%s"%s,"tooltip":"%s"}\n' "$_emit_t" "$_emit_extra" "$_emit_tt"
}

# find_battery : chemin sysfs de la première batterie (BAT0, BAT1, …) qui
# expose sa charge ; code 1 sans batterie (desktop). Partagée par battery.sh
# et l'alerte batterie des notifications : même détection des deux côtés.
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

# Icônes batterie Nerd Font (Material Design), 11 niveaux (0-100% par pas de
# 10) : partagées par battery.sh et bluetooth.sh. Glyphes littéraux (et non
# printf '\U…') : insensibles à LC_ALL=C, qui en locale ASCII ne sait pas
# encoder ces codepoints du plan astral.
bat_icons=(󰂎 󰁺 󰁻 󰁼 󰁽 󰁾 󰁿 󰂀 󰂁 󰂂 󰁹)
bat_icon() { # $1 = pourcentage -> glyphe
    local idx=$(( ($1 + 5) / 10 ))
    (( idx < 0 )) && idx=0
    (( idx > 10 )) && idx=10
    printf '%s' "${bat_icons[idx]}"
}

# --- Lieu météo partagé ----------------------------------------------------
# Source unique de la ville + de ses coordonnées, utilisée par weather.sh ET par
# le night light (wlsunset-geo.sh) : ainsi le night light suit la même ville que
# la météo (changer de ville dans le menu météo change aussi le lieu du night
# light). État persistant dans $XDG_STATE_HOME/waybar.

weather_statedir() { printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/waybar"; }

# Nom de ville -> fragment de nom de fichier (caches par ville).
weather_slug() { printf '%s' "${1//[^A-Za-z0-9]/_}"; }

# Ville courante (écrite par le menu clic-droit du module météo, cf.
# weather-city.sh). Défaut : WEATHER_DEFAULT_CITY, la première de
# `weatherCities` (posée par scripts.nix).
weather_city() {
    local city
    city=$(cat "$(weather_statedir)/weather-city" 2>/dev/null) || true
    [[ -z "$city" ]] && city=$WEATHER_DEFAULT_CITY
    printf '%s' "$city"
}

# "lat lon" d'une ville. Cache persistant par ville ; géocode via Open-Meteo
# (sans clé) si absent puis met en cache. Sortie vide + code !=0 si ni cache ni
# réseau (l'appelant gère le repli).
weather_coords() { # $1 = ville
    local city=$1 statedir coordcache geo lat lon
    statedir=$(weather_statedir)
    coordcache="$statedir/weather-$(weather_slug "$city").coords"
    if [[ -s "$coordcache" ]]; then
        cat "$coordcache"
        return 0
    fi
    # || true : curl en échec (pas de réseau) ne doit pas tuer le script
    # appelant (set -e) avant le repli return 1 ci-dessous.
    geo=$(curl -fsS --max-time 8 -G "https://geocoding-api.open-meteo.com/v1/search" \
        --data-urlencode "name=${city}" \
        --data "count=1&language=fr&format=json" 2>/dev/null) || true
    read -r lat lon <<<"$(jq -r '.results[0] | "\(.latitude) \(.longitude)"' <<<"$geo" 2>/dev/null)"
    [[ -n "$lat" && "$lat" != "null" ]] || return 1
    mkdir -p "$statedir"
    printf '%s %s' "$lat" "$lon" >"$coordcache"
    printf '%s %s' "$lat" "$lon"
}
