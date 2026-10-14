# shellcheck shell=bash
# Attente d'une fenêtre sway, partagée par les scripts qui lancent une appli
# puis la retouchent (flameshot, nwg-displays). Inliné en tête du script par
# le module appelant (`builtins.readFile`), comme waybar/scripts/lib.sh.
# Requiert swaymsg et jq dans le PATH.

# sway_wait TRIES DELAY FILTER : interroge l'arbre sway toutes les DELAY s,
# au plus TRIES fois, jusqu'à ce que le filtre jq FILTER sorte quelque chose
# de non vide ; l'affiche et réussit. Code 1 au bout du compte.
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

# sway_wait_stable TRIES DELAY FILTER : comme sway_wait, mais attend que la
# sortie (non vide) soit IDENTIQUE deux relevés de suite — fenêtre GTK qui se
# redimensionne elle-même juste après son ouverture.
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
