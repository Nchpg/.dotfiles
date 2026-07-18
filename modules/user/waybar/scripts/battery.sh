#!/usr/bin/env bash
# Batterie (module custom). Remplace le module `battery` natif pour pouvoir
# afficher, EN PLUS du %/temps/santé/cycles, deux infos que le tooltip-format
# natif ne sait pas produire (ses placeholders sont figés) :
#   - le profil d'alimentation (performance / équilibré / économie), via
#     power-profiles-daemon (powerprofilesctl) ;
#   - le régime des ventilateurs : état marche/arrêt (acpi_fan) + mode LG
#     (lg-laptop/fan_mode : silencieux vs performance).
#
# Sortie JSON : icône + % dans la barre, `class` pour la couleur CSS
# (charging/warning/critical, cf. #custom-battery dans default.nix), détail
# complet en tooltip. json_escape vient de lib.sh (inliné en tête au build).

export LC_ALL=C

# Première batterie trouvée (BAT0, BAT1, …) : même détection que le script
# de notifications (modules/user/notifications), plus de BAT0 en dur.
bat=""
for d in /sys/class/power_supply/BAT*; do
    [[ -d $d ]] && bat=$d && break
done
if [[ -z $bat ]]; then
    printf '{"text":"󰂑  N/A","tooltip":"Batterie indisponible"}\n'
    exit 0
fi

capacity=$(<"$bat/capacity")
status=$(<"$bat/status")

# Icône batterie : bat_icon vient de lib.sh (partagée avec bluetooth.sh) —
# mêmes 11 niveaux que le format-icons du module natif, à garder synchronisés.
icon=$(bat_icon "$capacity")

# En charge : éclair sur batterie (md-battery-charging). Pleine : icône pleine.
class=""
case "$status" in
    Charging)     icon=󰂄 ; class=charging ;;
    Full)         icon=󰁹 ;;
esac
# Seuils de couleur : repris des `states` du module natif (warning 20, crit 10).
# La charge a priorité (vert/charging) sur l'alerte de niveau bas.
if [[ $class != charging ]]; then
    if   (( capacity <= 10 )); then class=critical
    elif (( capacity <= 20 )); then class=warning
    fi
fi

# --- Temps restant : energy_now / power_now (heures), comme {time} natif. -----
# En charge -> temps jusqu'au plein ; en décharge -> jusqu'au vide. Vide si la
# puissance instantanée est nulle/inconnue (plein, ou état transitoire).
time_str=""
power_now=$(<"$bat/power_now")
energy_now=$(<"$bat/energy_now")
energy_full=$(<"$bat/energy_full")
if [[ $power_now =~ ^[0-9]+$ ]] && (( power_now > 0 )); then
    if [[ $status == Charging ]]; then
        remaining=$(( energy_full - energy_now ))
    else
        remaining=$energy_now
    fi
    if (( remaining > 0 )); then
        mins=$(( remaining * 60 / power_now ))
        time_str="$(( mins / 60 )) h $(printf '%02d' $(( mins % 60 ))) min"
    fi
fi

# --- Santé (capacité pleine actuelle / d'origine) + cycles -------------------
health=""
energy_full_design=$(<"$bat/energy_full_design")
if [[ $energy_full_design =~ ^[0-9]+$ ]] && (( energy_full_design > 0 )); then
    health=$(( (energy_full * 100 + energy_full_design / 2) / energy_full_design ))
fi
cycles=$(cat "$bat/cycle_count" 2>/dev/null)

# --- Profil d'alimentation (power-profiles-daemon) ---------------------------
profile=""
if command -v powerprofilesctl &>/dev/null; then
    case "$(powerprofilesctl get 2>/dev/null)" in
        performance) profile="Performance" ;;
        balanced)    profile="Équilibré" ;;
        power-saver) profile="Économie" ;;
    esac
fi

# --- Ventilateurs : état (acpi_fan) + mode (lg-laptop) -----------------------
# Le numéro hwmon n'est pas stable : on cherche le capteur nommé "acpi_fan"
# dont fan1_input est numérique (deux acpi_fan existent, l'un sans valeur).
# /!\ La « vitesse » ACPI (_FST) de ce LG est un faux tachymètre : 10 000
# tr/min constants dès que le ventilo tourne (valeur en dur du firmware, pas
# une mesure). On n'affiche donc que marche/arrêt, jamais le chiffre.
fan_rpm=""
for namefile in /sys/class/hwmon/hwmon*/name; do
    [[ $(<"$namefile") == acpi_fan ]] || continue
    v=$(cat "${namefile%/name}/fan1_input" 2>/dev/null)
    [[ $v =~ ^[0-9]+$ ]] && { fan_rpm=$v; break; }
done
case "$(cat /sys/devices/platform/lg-laptop/fan_mode 2>/dev/null)" in
    0) fan_mode="silencieux" ;;
    1) fan_mode="performance" ;;
    *) fan_mode="" ;;
esac

# --- Tooltip multi-lignes (vraies \n, converties par json_escape) ------------
tooltip="${capacity}%"
[[ -n "$time_str" ]] && tooltip+="  ·  ${time_str}"
[[ -n "$health" ]] && tooltip+=$'\n'"Santé ${health}%  ·  ${cycles} cycles"
[[ -n "$profile" ]] && tooltip+=$'\n'"Profil  ${profile}"
if [[ -n "$fan_rpm" ]]; then
    if (( fan_rpm > 0 )); then fan_line="en marche"; else fan_line="à l'arrêt"; fi
    [[ -n "$fan_mode" ]] && fan_line+=" · mode ${fan_mode}"
    tooltip+=$'\n'"Ventilateur  ${fan_line}"
fi

printf '{"text":"%s","class":"%s","tooltip":"%s"}\n' \
    "$(json_escape "${icon}  ${capacity}%")" "$class" "$(json_escape "$tooltip")"
