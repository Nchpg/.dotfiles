# shellcheck shell=bash
# Helpers JSON partagés par les modules custom waybar. Ce fichier n'a pas de
# shebang : il est inliné EN TÊTE de chaque script au build (cf. mkScript dans
# modules/user/window-manager/sway/waybar/default.nix), avant le corps du script. Centralise
# l'échappement JSON, qui n'était auparavant fait que dans bluetooth.sh.
#
# json_escape : échappe une valeur pour l'insérer dans un champ JSON (backslash,
# guillemet, et vraies nouvelles lignes -> \n pour les tooltips multi-lignes).
# Donc les scripts construisent leurs tooltips avec de VRAIES nouvelles lignes
# ($'\n'), pas des "\n" littéraux.
json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    printf '%s' "$s"
}

# json_escape_to : comme json_escape, mais écrit dans la variable nommée $1
# au lieu de stdout -> pas de sous-shell $(...), donc pas de fork. Pour les
# boucles qui tournent en continu (resources.sh).
json_escape_to() { # $1 = nom de variable, $2 = valeur
    local -n _je_out=$1
    local s=$2
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    _je_out=$s
}

# emit : JSON waybar { texte barre, tooltip (peut être vide) }, les deux échappés.
emit() {
    local _emit_t _emit_tt
    json_escape_to _emit_t "$1"
    json_escape_to _emit_tt "$2"
    printf '{"text":"%s","tooltip":"%s"}\n' "$_emit_t" "$_emit_tt"
}

# Icônes batterie Nerd Font (Material Design), 11 niveaux (0-100% par pas de
# 10) : partagées par battery.sh et bluetooth.sh (mêmes glyphes que le
# format-icons natif dans modules/user/window-manager/sway/waybar/default.nix -> garder les DEUX
# synchronisés si un jour ils changent). Glyphes littéraux (et non printf
# '\U…') : insensibles à LC_ALL=C, qui en locale ASCII ne sait pas encoder ces
# codepoints du plan astral.
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

# Ville courante (écrite par le menu clic-droit du module météo). Défaut Angers.
weather_city() {
    local city
    city=$(cat "$(weather_statedir)/weather-city" 2>/dev/null) || true
    [[ -z "$city" ]] && city="Angers"
    printf '%s' "$city"
}

# "lat lon" d'une ville. Cache persistant par ville ; géocode via Open-Meteo
# (sans clé) si absent puis met en cache. Sortie vide + code !=0 si ni cache ni
# réseau (l'appelant gère le repli).
weather_coords() { # $1 = ville
    local city=$1 statedir safe coordcache geo lat lon
    statedir=$(weather_statedir)
    safe=${city//[^A-Za-z0-9]/_}
    coordcache="$statedir/weather-${safe}.coords"
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
