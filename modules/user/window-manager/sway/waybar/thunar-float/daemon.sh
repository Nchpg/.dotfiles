# shellcheck shell=bash
# Sway n'a pas de raccourci conditionnel au focus : Échap est lié à la prise de
# focus et retiré à sa perte. Pas de `q` : il fermerait la fenêtre pendant une saisie.

dir="${XDG_RUNTIME_DIR:-/tmp}/thunar-float"
mkdir -p "$dir"

float_id="" focused="" bound=0

unbind() {
    ((bound)) || return 0
    swaymsg -q 'unbindsym Escape' 2>/dev/null || true
    bound=0
}
bind() {
    ((bound)) && return 0
    if swaymsg -q "bindsym --no-repeat Escape [con_id=$float_id] kill"; then
        bound=1
    fi
}
# Échap ne doit jamais rester capturé : retiré au départ et à la sortie
cleanup() {
    swaymsg -q 'unbindsym Escape' 2>/dev/null || true
    local pids
    mapfile -t pids < <(jobs -p)
    ((${#pids[@]} == 0)) || kill "${pids[@]}" 2>/dev/null || true
}
cleanup
trap cleanup EXIT
# SIGTERM passe par le trap EXIT
trap 'exit 0' TERM INT HUP

hz=$(getconf CLK_TCK)

# GIO détache les applis (pas de filiation) mais marque leur environnement
# (GIO_LAUNCHED_DESKTOP_FILE) ; on exige aussi moins de 15 s d'âge.
launched_by_file() {
    local pid=$1 stat start up
    [ "$pid" -gt 1 ] 2>/dev/null || return 1
    grep -qz '^GIO_LAUNCHED_DESKTOP_FILE=' /proc/"$pid"/environ 2>/dev/null || return 1
    stat=$(</proc/"$pid"/stat) || return 1
    stat=${stat##*) } # après « (comm) », qui peut contenir des espaces
    read -r -a fields <<<"$stat"
    start=${fields[19]} # starttime : 22e champ, 20e après « (comm) »
    read -r up _ </proc/uptime
    up=${up%.*}
    ((up - start / hz < 15))
}

swaymsg -t subscribe -m '["window"]' \
    | jq --unbuffered -r '[.change, .container.id, (.container.app_id // ""), (.container.pid // 0), .container.type] | @tsv' \
    | while IFS=$'\t' read -r change id app pid type; do
        case $change in
            new)
                if [ "$app" = thunar ] && [ -f "$dir/pending" ] \
                    && (($(date +%s) - $(stat -c %Y "$dir/pending") < 10)); then
                    rm -f "$dir/pending"
                    float_id=$id
                    # Déjà flottante : la règle du launcher a joué. Sinon rattrapage.
                    if [ "$type" != floating_con ]; then
                        swaymsg -q "[con_id=$id] floating enable, resize set 1200 750, move position center" || true
                        # Thunar impose sa taille juste après s'être affiché.
                        (sleep 0.4 && swaymsg -q "[con_id=$id] resize set 1200 750, move position center") >/dev/null 2>&1 &
                    fi
                elif [ -n "$float_id" ] && [ "$focused" = "$float_id" ] \
                    && [ "$app" != thunar ] && launched_by_file "$pid"; then
                    swaymsg -q "[con_id=$float_id] kill" || true
                fi
                ;;
            focus)
                focused=$id
                if [ -n "$float_id" ] && [ "$id" = "$float_id" ]; then bind; else unbind; fi
                ;;
            close)
                if [ "$id" = "$float_id" ]; then
                    float_id=""
                    unbind
                fi
                ;;
        esac
    done &
# En fond + `wait` : bash ne traite un signal qu'entre deux commandes
wait $!
