#!/usr/bin/env bash
# RAM / CPU / GPU pour waybar (module custom, sortie JSON : texte compact dans
# la barre + détail en tooltip).
#
# CPU : usage instantané calculé via le delta de /proc/stat entre deux passages
# (état stocké), comme le GPU — bien plus juste et léger qu'un `top -bn1`, dont
# le %Cpu est une moyenne depuis le boot (qui ne bouge donc quasi jamais).
# RAM : lue dans /proc/meminfo (total - MemAvailable) -> pas de `free` (process
# en moins, et indépendant de la locale).
# GPU Intel (driver xe) : pas de gpu_busy_percent en sysfs, on calcule le %
# occupé via le delta d'idle_residency_ms entre deux passages.

export LC_ALL=C
state_dir="${XDG_RUNTIME_DIR:-/tmp}"

# --- RAM (/proc/meminfo, en Kio) ---
read -r mem_total mem_avail < <(
    awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {print t, a}' /proc/meminfo
)
mem_used_kb=$((mem_total - mem_avail))
mem_pct=$((mem_used_kb * 100 / mem_total))
mem_used_gb=$(awk "BEGIN {printf \"%.1f\", $mem_used_kb/1048576}")
mem_total_gb=$(awk "BEGIN {printf \"%.1f\", $mem_total/1048576}")

# --- CPU (delta /proc/stat) ---
cpu() {
    local state="$state_dir/waybar-cpu.state"
    local user nice system idle iowait irq softirq steal
    local total prev_idle prev_total d_idle d_total pct=0
    read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
    idle=$((idle + iowait))
    total=$((user + nice + system + idle + irq + softirq + steal))
    if [[ -r "$state" ]]; then
        read -r prev_idle prev_total < "$state"
        d_idle=$((idle - prev_idle))
        d_total=$((total - prev_total))
        if (( d_total > 0 )); then
            pct=$(( (d_total - d_idle) * 100 / d_total ))
            (( pct < 0 )) && pct=0
            (( pct > 100 )) && pct=100
        fi
    fi
    echo "$idle $total" > "$state"
    echo "$pct"
}
cpu_pct=$(cpu)

# --- GPU (delta idle_residency_ms) ---
gpu() {
    local idle_file="" state now_idle now_ms prev_idle prev_ms d_idle d_ms busy=0
    for f in /sys/class/drm/card*/device/tile0/gt0/gtidle/idle_residency_ms; do
        [[ -r "$f" ]] && { idle_file="$f"; break; }
    done
    if [[ -z "$idle_file" ]]; then
        echo "N/A"
        return
    fi
    state="$state_dir/waybar-gpu.state"
    now_idle=$(<"$idle_file")
    now_ms=$(date +%s%3N)
    if [[ -r "$state" ]]; then
        read -r prev_idle prev_ms < "$state"
        d_idle=$((now_idle - prev_idle))
        d_ms=$((now_ms - prev_ms))
        if (( d_ms > 0 )); then
            busy=$(( (d_ms - d_idle) * 100 / d_ms ))
            (( busy < 0 )) && busy=0
            (( busy > 100 )) && busy=100
        fi
    fi
    echo "$now_idle $now_ms" > "$state"
    echo "${busy}%"
}
gpu_val=$(gpu)

# --- Charge système (load average) normalisée par cœur -> % ---
# 100 % = tous les cœurs pleinement sollicités ; >100 % = des tâches attendent.
read -r load1 load5 load15 _ < /proc/loadavg
ncpu=$(nproc)
read -r load1_pct load5_pct load15_pct < <(
    awk -v n="$ncpu" -v a="$load1" -v b="$load5" -v c="$load15" \
        'BEGIN { printf "%d %d %d", a/n*100+0.5, b/n*100+0.5, c/n*100+0.5 }'
)

# --- Sortie JSON ---
text="󰍛   RAM : ${mem_pct}%  CPU ${cpu_pct}%  GPU ${gpu_val}"
tooltip="RAM   ${mem_used_gb} / ${mem_total_gb} Gio  (${mem_pct}%)"
tooltip+="\nCPU   ${cpu_pct}%  ·  charge 1 min : ${load1_pct}%   5 min : ${load5_pct}%   15 min : ${load15_pct}%"
tooltip+="\nGPU   ${gpu_val}"
printf '{"text":"%s","tooltip":"%s"}\n' "$text" "$tooltip"
