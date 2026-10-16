# shellcheck shell=bash
# sway_wait TRIES DELAY FILTER : affiche la sortie non vide du filtre jq ; code 1 sinon.
sway_wait() {
    local tries=$1 delay=$2 filter=$3 out i
    for ((i = 0; i < tries; i++)); do
        out=$(swaymsg -t get_tree | jq -r "$filter")
        if [ -n "$out" ]; then
            printf '%s\n' "$out"
            return 0
        fi
        sleep "$delay"
    done
    return 1
}

# Comme sway_wait, mais la sortie doit être identique deux relevés de suite.
sway_wait_stable() {
    local tries=$1 delay=$2 filter=$3 prev="" cur n=1
    cur=$(swaymsg -t get_tree | jq -r "$filter")
    while [ -z "$cur" ] || [ "$cur" != "$prev" ]; do
        if ((n >= tries)); then
            return 1
        fi
        n=$((n + 1))
        sleep "$delay"
        prev=$cur
        cur=$(swaymsg -t get_tree | jq -r "$filter")
    done
    printf '%s\n' "$cur"
}
