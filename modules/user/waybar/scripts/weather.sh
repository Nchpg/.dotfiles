#!/usr/bin/env bash
# Météo courante via wttr.in (géolocalisation par IP, sans clé API). Sortie JSON :
# barre = icône + température, tooltip = lieu / description / ressenti / vent.
#
# L'icône n'est PAS écrite ici : on émet une CATÉGORIE dans le champ "alt", et
# waybar la mappe sur le glyphe Material Design défini côté Nix (format-icons).
# Ça évite les glyphes astraux en dur et garde la cohérence avec la barre.
#
# Jour/nuit est déduit de l'heure locale (ciel clair / partiellement couvert ont
# une icône différente la nuit). En cas d'absence de réseau, on réutilise le
# dernier relevé en cache, sinon on affiche l'état "offline".

export LC_ALL=C

# Ville choisie via le menu clic-droit, persistée hors du store Nix (survit aux
# reboots et rebuilds). La géoloc par IP n'est pas fiable (beaucoup de FAI FR
# sortent à Paris), donc on s'appuie sur ce choix explicite. Défaut : Angers.
state="${XDG_STATE_HOME:-$HOME/.local/state}/waybar/weather-city"
location=$(cat "$state" 2>/dev/null)
[[ -z "$location" ]] && location="Angers"

# Cache par ville : switcher de ville hors-ligne n'affiche pas un vieux relevé
# d'une autre ville.
safe=${location//[^A-Za-z0-9]/_}
cache="${XDG_RUNTIME_DIR:-/tmp}/waybar-weather-${safe}.json"

# 7h–20h = jour, sinon nuit (pour les icônes "clear"/"partly").
hour=$(date +%H)
if ((10#$hour >= 7 && 10#$hour < 20)); then day=1; else day=0; fi

# Récupère le relevé j1 (JSON complet) ; à défaut on bascule sur le cache.
# lang=fr -> ajoute un champ lang_fr (description traduite) au relevé.
json=$(curl -fsS --max-time 8 "https://wttr.in/${location}?format=j1&lang=fr" 2>/dev/null)
if [[ -n "$json" ]] && jq -e . >/dev/null 2>&1 <<<"$json"; then
    printf '%s' "$json" >"$cache"
else
    json=$(cat "$cache" 2>/dev/null)
fi

if [[ -z "$json" ]]; then
    printf '{"text":"--","alt":"offline","tooltip":"Météo indisponible"}\n'
    exit 0
fi

read -r temp feels code humidity wind winddir <<<"$(
    jq -r '.current_condition[0]
        | "\(.temp_C) \(.FeelsLikeC) \(.weatherCode) \(.humidity) \(.windspeedKmph) \(.winddir16Point)"' \
        <<<"$json"
)"
# Description en français (lang_fr) avec repli sur l'anglais si absent.
desc=$(jq -r '.current_condition[0] | (.lang_fr[0].value // .weatherDesc[0].value)' <<<"$json")

# Codes WWO (wttr.in) -> catégorie d'icône. Regroupés par intensité.
case "$code" in
    113) cat=$([[ $day == 1 ]] && echo clear-day || echo clear-night) ;;
    116) cat=$([[ $day == 1 ]] && echo partly-day || echo partly-night) ;;
    119 | 122) cat=cloudy ;;
    143 | 248 | 260) cat=fog ;;
    176 | 185 | 263 | 266 | 281 | 293 | 296 | 353) cat=rain-light ;;
    299 | 302 | 305 | 308 | 356 | 359) cat=rain ;;
    179 | 182 | 317 | 320 | 362 | 365) cat=sleet ;;
    227 | 230 | 323 | 326 | 329 | 332 | 368 | 371) cat=snow ;;
    335 | 338 | 392 | 395) cat=snow-heavy ;;
    284 | 311 | 314 | 350 | 374 | 377) cat=hail ;;
    200 | 386 | 389) cat=thunder ;;
    *) cat=cloudy ;;
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
# En-tête = le preset choisi (et non le quartier renvoyé par wttr.in).
tooltip="${location} · ${desc}"
tooltip+="\nRessenti ${feels}°  ·  Humidité ${humidity}%"
tooltip+="\nVent ${wind} km/h ${winddir}"
tooltip+="\n<i>Clic droit : changer de ville</i>"

printf '{"text":"%s","alt":"%s","class":"%s","tooltip":"%s"}\n' "$text" "$cat" "$class" "$tooltip"
