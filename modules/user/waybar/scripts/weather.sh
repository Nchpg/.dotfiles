#!/usr/bin/env bash
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

# Ville choisie via le menu clic-droit, persistée hors du store Nix (survit aux
# reboots et rebuilds). Défaut : Angers.
state="${XDG_STATE_HOME:-$HOME/.local/state}/waybar/weather-city"
location=$(cat "$state" 2>/dev/null)
[[ -z "$location" ]] && location="Angers"

# Caches par ville : switcher de ville hors-ligne n'affiche pas un vieux relevé
# d'une autre ville. On cache les coordonnées (géocodage) ET le relevé.
safe=${location//[^A-Za-z0-9]/_}
cache="${XDG_RUNTIME_DIR:-/tmp}/waybar-weather-${safe}.json"
coordcache="${XDG_RUNTIME_DIR:-/tmp}/waybar-weather-${safe}.coords"

# --- Géocodage ville -> lat/lon (API geocoding Open-Meteo, sans clé) ---
geo=$(curl -fsS --max-time 8 -G "https://geocoding-api.open-meteo.com/v1/search" \
    --data-urlencode "name=${location}" \
    --data "count=1&language=fr&format=json" 2>/dev/null)
read -r lat lon <<<"$(jq -r '.results[0] | "\(.latitude) \(.longitude)"' <<<"$geo" 2>/dev/null)"
if [[ -n "$lat" && "$lat" != "null" ]]; then
    printf '%s %s' "$lat" "$lon" >"$coordcache"
else
    read -r lat lon <<<"$(cat "$coordcache" 2>/dev/null)"
fi

# --- Relevé courant pour ces coordonnées ; à défaut on bascule sur le cache ---
if [[ -n "$lat" && "$lat" != "null" ]]; then
    json=$(curl -fsS --max-time 8 -G "https://api.open-meteo.com/v1/forecast" \
        --data-urlencode "latitude=${lat}" \
        --data-urlencode "longitude=${lon}" \
        --data "current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,wind_direction_10m,is_day&timezone=auto" \
        2>/dev/null)
fi
if [[ -n "$json" ]] && jq -e .current >/dev/null 2>&1 <<<"$json"; then
    printf '%s' "$json" >"$cache"
else
    json=$(cat "$cache" 2>/dev/null)
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
    0)  cat=$([[ $isday == 1 ]] && echo clear-day || echo clear-night);  desc="Ciel dégagé" ;;
    1)  cat=$([[ $isday == 1 ]] && echo clear-day || echo clear-night);  desc="Plutôt dégagé" ;;
    2)  cat=$([[ $isday == 1 ]] && echo partly-day || echo partly-night); desc="Partiellement nuageux" ;;
    3)  cat=cloudy;     desc="Couvert" ;;
    45) cat=fog;        desc="Brouillard" ;;
    48) cat=fog;        desc="Brouillard givrant" ;;
    51) cat=rain-light; desc="Bruine légère" ;;
    53) cat=rain-light; desc="Bruine modérée" ;;
    55) cat=rain-light; desc="Bruine dense" ;;
    56) cat=sleet;      desc="Bruine verglaçante légère" ;;
    57) cat=sleet;      desc="Bruine verglaçante dense" ;;
    61) cat=rain-light; desc="Pluie faible" ;;
    63) cat=rain;       desc="Pluie modérée" ;;
    65) cat=rain;       desc="Pluie forte" ;;
    66) cat=sleet;      desc="Pluie verglaçante faible" ;;
    67) cat=sleet;      desc="Pluie verglaçante forte" ;;
    71) cat=snow;       desc="Neige faible" ;;
    73) cat=snow;       desc="Neige modérée" ;;
    75) cat=snow-heavy; desc="Neige forte" ;;
    77) cat=snow;       desc="Grains de neige" ;;
    80) cat=rain-light; desc="Averses faibles" ;;
    81) cat=rain;       desc="Averses modérées" ;;
    82) cat=rain;       desc="Averses violentes" ;;
    85) cat=snow;       desc="Averses de neige faibles" ;;
    86) cat=snow-heavy; desc="Averses de neige fortes" ;;
    95) cat=thunder;    desc="Orage" ;;
    96) cat=thunder;    desc="Orage, grêle légère" ;;
    99) cat=thunder;    desc="Orage, grêle forte" ;;
    *)  cat=cloudy;     desc="Conditions inconnues" ;;
esac

# Classe CSS (couleur dynamique du module, cf. style dans default.nix). On
# regroupe les catégories en 4 ambiances : ensoleillé (jaune), couvert (gris),
# pluie/neige (bleu), et le reste garde la couleur de base (cyan).
case "$cat" in
    clear-*) class=sunny ;;
    cloudy | fog) class=cloudy ;;
    rain* | sleet | snow* | hail | thunder) class=rain ;;
    *) class=default ;;
esac

text="${temp}°"
# En-tête = le preset choisi (et non le lieu géocodé renvoyé par l'API).
tooltip="${location} · ${desc}"
tooltip+="\nRessenti ${feels}°  ·  Humidité ${humidity}%"
tooltip+="\nVent ${wind} km/h ${winddir}"
tooltip+="\n<i>Clic droit : changer de ville</i>"

printf '{"text":"%s","alt":"%s","class":"%s","tooltip":"%s"}\n' "$text" "$cat" "$class" "$tooltip"
