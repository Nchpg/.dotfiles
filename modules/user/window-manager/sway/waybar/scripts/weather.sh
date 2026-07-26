#!/usr/bin/env bash
set -euo pipefail
# Météo courante via Open-Meteo (gratuit, sans clé API). Sortie JSON :
# barre = icône + température, tooltip = lieu / description / ressenti / vent.
#
# Open-Meteo a été préféré à wttr.in pour le ressenti : son champ
# `apparent_temperature` combine température, humidité, vent ET rayonnement
# solaire, alors que le `FeelsLikeC` de wttr.in (Heat Index NWS) devient faux en
# air sec (< ~40% d'humidité) où il passe sous la température réelle.
#
# L'icône n'est PAS écrite ici : on émet une CATÉGORIE dans le champ "alt", et
# waybar la mappe sur le glyphe Material Design défini côté Nix (format-icons).
# Ça évite les glyphes astraux en dur et garde la cohérence avec la barre.
#
# Jour/nuit vient du champ `is_day` de l'API (ciel clair / partiellement couvert
# ont une icône différente la nuit). En cas d'absence de réseau, on réutilise le
# dernier relevé en cache, sinon on affiche l'état "offline".

export LC_ALL=C

# Répertoire d'état persistant (survit aux reboots et rebuilds) : il porte la
# ville choisie ET les caches (coords + relevé). Auparavant coords/relevé
# vivaient dans $XDG_RUNTIME_DIR (tmpfs, effacé au reboot) -> après un reboot
# hors-ligne on perdait tout (affichage "--"). En state, le dernier relevé
# connu reste affichable et on évite même un géocodage au premier lancement.
statedir="${XDG_STATE_HOME:-$HOME/.local/state}/waybar"
mkdir -p "$statedir"

# Ville courante + ses coordonnées : logique partagée avec le night light (cf.
# weather_city / weather_coords dans lib.sh). weather_coords réutilise le cache
# de coords par ville et ne géocode qu'au premier affichage d'une ville (ou si
# le cache a disparu) -> une requête HTTP en moins par cycle.
location=$(weather_city)
safe=${location//[^A-Za-z0-9]/_}
cache="$statedir/weather-${safe}.json"     # cache du relevé courant (par ville)
read -r lat lon <<<"$(weather_coords "$location")"

# --- Relevé courant pour ces coordonnées ; à défaut on bascule sur le cache ---
# json initialisé à vide : sous `set -u`, si lat est vide (géocodage
# indisponible), le bloc ci-dessous est sauté et $json serait sinon "unbound".
json=""
if [[ -n "$lat" && "$lat" != "null" ]]; then
    # || true : curl en échec (pas de réseau) ne doit pas tuer le script avant
    # le repli sur le cache juste en dessous.
    json=$(curl -fsS --max-time 8 -G "https://api.open-meteo.com/v1/forecast" \
        --data-urlencode "latitude=${lat}" \
        --data-urlencode "longitude=${lon}" \
        --data "current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,wind_direction_10m,is_day&timezone=auto" \
        2>/dev/null) || true
fi
if [[ -n "$json" ]] && jq -e .current >/dev/null 2>&1 <<<"$json"; then
    printf '%s' "$json" >"$cache"
else
    json=$(cat "$cache" 2>/dev/null) || true # pas de cache -> repli "offline" plus bas
fi

# Pas de relevé exploitable (ni réseau, ni cache au bon format) -> offline.
if [[ -z "$json" ]] || ! jq -e .current >/dev/null 2>&1 <<<"$json"; then
    printf '{"text":"--","alt":"offline","tooltip":"Météo indisponible"}\n'
    exit 0
fi

read -r temp feels code humidity wind winddeg isday <<<"$(
    jq -r '.current
        | "\(.temperature_2m) \(.apparent_temperature) \(.weather_code) \(.relative_humidity_2m) \(.wind_speed_10m) \(.wind_direction_10m) \(.is_day)"' \
        <<<"$json"
)"

# Arrondis pour l'affichage (l'API renvoie des flottants : 40.7, 16.2, ...).
temp=$(printf '%.0f' "$temp")
feels=$(printf '%.0f' "$feels")
wind=$(printf '%.0f' "$wind")
humidity=$(printf '%.0f' "$humidity")

# Direction du vent : degrés -> rose des vents 16 points (FR, O = Ouest).
deg=$(printf '%.0f' "$winddeg")
dirs=(N NNE NE ENE E ESE SE SSE S SSO SO OSO O ONO NO NNO)
winddir=${dirs[$(((deg * 100 + 1125) / 2250 % 16))]}

# Codes WMO (Open-Meteo) -> catégorie d'icône + description FR.
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

# Classe CSS (couleur dynamique du module, cf. style dans default.nix). On
# regroupe les catégories en 4 ambiances : ensoleillé (jaune), couvert (gris),
# pluie/neige (bleu), et le reste garde la couleur de base (cyan).
case "$wcat" in
    clear-*) class=sunny ;;
    cloudy | fog) class=cloudy ;;
    rain* | sleet | snow* | hail | thunder) class=rain ;;
    *) class=default ;;
esac

text="${temp}°"
# Dernière actualisation = date d'écriture du cache (mtime). En cas de relevé
# frais c'est « maintenant » ; hors-ligne, c'est le dernier relevé réussi.
updated=$(date -r "$cache" '+%d/%m %H:%M' 2>/dev/null) || true
# En-tête = le preset choisi (et non le lieu géocodé renvoyé par l'API).
# Tooltip multi-lignes en VRAIES nouvelles lignes ; json_escape (lib.sh) les
# convertit en \n.
tooltip="${location} · ${desc}"
tooltip+=$'\n'"Ressenti ${feels}°  ·  Humidité ${humidity}%"
tooltip+=$'\n'"Vent ${wind} km/h ${winddir}"
[[ -n "$updated" ]] && tooltip+=$'\n'"Maj ${updated}"

printf '{"text":"%s","alt":"%s","class":"%s","tooltip":"%s"}\n' \
    "$(json_escape "$text")" "$wcat" "$class" "$(json_escape "$tooltip")"
