#!/usr/bin/env bash
set -euo pipefail
# RAM / CPU / GPU pour waybar (module custom, sortie JSON : texte compact dans
# la barre + détail en tooltip).
#
# FLUX CONTINU (comme nowplaying.sh) : un seul process vit tout du long et
# écrit une ligne JSON toutes les $period s. L'ancien mode (waybar relançant
# le script toutes les 3 s) coûtait ~11 processus par tour (bash, awk ×4,
# date, nproc, sous-shells) : ~220 forks/min pour cette seule case. Ici :
# un `sleep` par tour, tout le reste en builtins bash, état en variables.
#
# CPU : usage instantané via le delta de /proc/stat entre deux tours (un
# `top -bn1` donne une moyenne depuis le boot, qui ne bouge quasi jamais).
# RAM : /proc/meminfo (total - MemAvailable), indépendant de la locale.
# GPU Intel (driver xe) : pas de gpu_busy_percent en sysfs, % occupé calculé
# via le delta d'idle_residency_ms entre deux tours.

export LC_ALL=C
period=3

# --- Recherches faites une seule fois (chemins stables pendant la session) ---
ncpu=$(nproc)

gpu_idle_file=""
for f in /sys/class/drm/card*/device/tile0/gt0/gtidle/idle_residency_ms; do
    [[ -r "$f" ]] && { gpu_idle_file="$f"; break; }
done

# Température du package CPU (coretemp, « Package id 0 ») : LA température
# utile du SoC (l'iGPU Meteor Lake est dans le même package, la LPDDR soudée
# n'a pas de capteur). Numéro hwmon instable entre boots -> recherche par nom.
cpu_temp_file=""
for namefile in /sys/class/hwmon/hwmon*/name; do
    [[ $(<"$namefile") == coretemp ]] || continue
    h=${namefile%/name}
    for lbl in "$h"/temp*_label; do
        [[ -e "$lbl" && $(<"$lbl") == "Package id 0" ]] || continue
        cpu_temp_file="${lbl%_label}_input"
        break 2
    done
done

# Millisecondes depuis l'epoch, sans `date` ($EPOCHREALTIME : « s.µs », avec
# le séparateur décimal de la locale -> on retire . ou ,).
now_ms() { local t=${EPOCHREALTIME//[.,]/}; printf -v "$1" '%s' "$((10#$t / 1000))"; }

# Kio -> « x.y » Gio, en entiers arrondis (pas d'awk).
gib() { # $1 = variable de sortie, $2 = Kio
    local d=$(( ($2 * 10 + 524288) / 1048576 ))
    printf -v "$1" '%d.%d' $((d / 10)) $((d % 10))
}

# Load average « 1.05 » -> % de charge par cœur, arrondi (100 % = tous les
# cœurs pleins ; > 100 % = des tâches attendent). /proc/loadavg a toujours
# deux décimales.
load_pct() { # $1 = variable de sortie, $2 = load
    local c=${2/./}
    c=$((10#$c))
    printf -v "$1" '%d' $(( (2 * c + ncpu) / (2 * ncpu) ))
}

prev_idle=0 prev_total=0 prev_gpu_idle=0 prev_gpu_ms=0 first=1
# Remplies par sample() (en partie via printf -v, invisible pour shellcheck).
mem_pct=0 mem_used_gb="" mem_total_gb="" cpu_pct=0 gpu_val="" cpu_temp=""
load1_pct=0 load5_pct=0 load15_pct=0

sample() {
    # --- RAM ---
    local key val _ mem_total=0 mem_avail=0
    while read -r key val _; do
        case $key in
            MemTotal:) mem_total=$val ;;
            MemAvailable:) mem_avail=$val; break ;;
        esac
    done </proc/meminfo
    local mem_used=$((mem_total - mem_avail))
    mem_pct=$((mem_used * 100 / mem_total))
    gib mem_used_gb "$mem_used"
    gib mem_total_gb "$mem_total"

    # --- CPU (delta /proc/stat) ---
    local user nice system idle iowait irq softirq steal total d_idle d_total
    read -r _ user nice system idle iowait irq softirq steal _ </proc/stat
    idle=$((idle + iowait))
    total=$((user + nice + system + idle + irq + softirq + steal))
    cpu_pct=0
    d_idle=$((idle - prev_idle))
    d_total=$((total - prev_total))
    if ((!first && d_total > 0)); then
        cpu_pct=$(((d_total - d_idle) * 100 / d_total))
        ((cpu_pct < 0)) && cpu_pct=0
        ((cpu_pct > 100)) && cpu_pct=100
    fi
    prev_idle=$idle prev_total=$total

    # --- GPU (delta idle_residency_ms) ---
    if [[ -z "$gpu_idle_file" ]]; then
        gpu_val="N/A"
    else
        local g_idle g_ms d_g d_ms busy=0
        read -r g_idle <"$gpu_idle_file"
        now_ms g_ms
        d_g=$((g_idle - prev_gpu_idle))
        d_ms=$((g_ms - prev_gpu_ms))
        if ((!first && d_ms > 0)); then
            busy=$(((d_ms - d_g) * 100 / d_ms))
            ((busy < 0)) && busy=0
            ((busy > 100)) && busy=100
        fi
        prev_gpu_idle=$g_idle prev_gpu_ms=$g_ms
        gpu_val="${busy}%"
    fi

    # --- Température ---
    cpu_temp=""
    if [[ -n "$cpu_temp_file" ]]; then
        local t=""
        read -r t <"$cpu_temp_file" || true
        [[ $t =~ ^[0-9]+$ ]] && cpu_temp=$((t / 1000))
    fi

    # --- Charge ---
    local l1 l5 l15
    read -r l1 l5 l15 _ </proc/loadavg
    load_pct load1_pct "$l1"
    load_pct load5_pct "$l5"
    load_pct load15_pct "$l15"
    first=0
}

# Premier relevé pour amorcer les deltas CPU/GPU, puis 1 s avant d'afficher :
# pas de « CPU 0 % » trompeur au lancement de la barre.
sample
sleep 1

while :; do
    sample
    # emit + json_escape_to : cf. lib.sh (sans sous-shell)
    text="󰍛   RAM : ${mem_pct}%  CPU ${cpu_pct}%  GPU ${gpu_val}"
    tooltip="RAM   ${mem_used_gb} / ${mem_total_gb} Gio  (${mem_pct}%)"
    tooltip+=$'\n'"CPU   ${cpu_pct}%${cpu_temp:+  ·  ${cpu_temp}°C}  ·  charge 1 min : ${load1_pct}%   5 min : ${load5_pct}%   15 min : ${load15_pct}%"
    tooltip+=$'\n'"GPU   ${gpu_val}"
    emit "$text" "$tooltip"
    sleep "$period"
done
