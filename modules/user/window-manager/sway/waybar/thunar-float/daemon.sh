# shellcheck shell=bash
# (Pas de shebang : writeShellApplication l'ajoute, avec set -euo pipefail.)
#
# Thunar « éphémère », ouvert par le clic sur la case disque de waybar
# (launcher.sh) : flottant et centré, fermé par Échap ou q, et fermé tout seul
# quand on y ouvre un fichier. Les Thunar ouverts autrement restent en tuile
# et normaux.
#
# Sway n'a pas de raccourci « seulement si telle fenêtre a le focus », et un
# mode désactiverait tous les autres raccourcis. On AJOUTE donc Échap et q à
# la volée quand la fenêtre éphémère prend le focus, et on les RETIRE dès
# qu'elle le perd : ailleurs, ces touches arrivent normalement aux applis.

dir="${XDG_RUNTIME_DIR:-/tmp}/thunar-float"
mkdir -p "$dir"

float_id="" focused="" bound=0

unbind() {
    ((bound)) || return 0
    swaymsg -q 'unbindsym Escape; unbindsym q' 2>/dev/null || true
    bound=0
}
bind() {
    ((bound)) && return 0
    if swaymsg -q "bindsym --no-repeat Escape [con_id=$float_id] kill; bindsym --no-repeat q [con_id=$float_id] kill"; then
        bound=1
    fi
}
# Jamais d'Échap/q volés au reste de la session si le démon s'arrête : on les
# retire au départ (reste d'une instance tuée) et à la sortie.
cleanup() {
    swaymsg -q 'unbindsym Escape; unbindsym q' 2>/dev/null || true
    # Le pipeline d'écoute (lancé en fond plus bas) part avec nous.
    local pids
    mapfile -t pids < <(jobs -p)
    ((${#pids[@]} == 0)) || kill "${pids[@]}" 2>/dev/null || true
}
cleanup
trap cleanup EXIT
# SIGTERM (arrêt du service, rebuild) : passe par le trap EXIT pour retirer
# Échap/q, sinon ils resteraient capturés pour toute la session.
trap 'exit 0' TERM INT HUP
# SIGTERM (arrêt du service, rebuild) : sans ça bash meurt sans passer par
# le trap EXIT, et Échap/q resteraient capturés pour toute la session.
trap 'exit 0' TERM INT HUP

hz=$(getconf CLK_TCK)

# La fenêtre du processus $1 vient-elle d'être lancée « par un fichier » ?
# Pas de filiation possible : GIO détache les applis qu'il lance (rattachées
# à systemd, pas à Thunar). Mais il marque leur environnement
# (GIO_LAUNCHED_DESKTOP_FILE) ; on exige en plus un processus de moins de
# 15 s, pour ignorer une appli déjà ouverte qui ferait apparaître une fenêtre.
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
    | jq --unbuffered -r '[.change, .container.id, (.container.app_id // ""), (.container.pid // 0)] | @tsv' \
    | while IFS=$'\t' read -r change id app pid; do
        case $change in
            new)
                # Fenêtre Thunar demandée par le clic waybar il y a < 10 s.
                if [ "$app" = thunar ] && [ -f "$dir/pending" ] \
                    && (($(date +%s) - $(stat -c %Y "$dir/pending") < 10)); then
                    rm -f "$dir/pending"
                    float_id=$id
                    swaymsg -q "[con_id=$id] floating enable, resize set 1200 750, move position center" || true
                    # Au premier lancement, Thunar impose sa taille juste après
                    # s'être affiché : on repasse derrière lui.
                    (sleep 0.4 && swaymsg -q "[con_id=$id] resize set 1200 750, move position center") >/dev/null 2>&1 &
                # Nouvelle fenêtre lancée PAR ce Thunar alors qu'il avait le
                # focus : un fichier vient d'y être ouvert. Les dialogues de
                # Thunar lui-même (renommer, propriétés...) sont exclus.
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
# En fond + `wait` : bash ne traite un signal qu'entre deux commandes, et ce
# pipeline ne se termine jamais. Au premier plan, SIGTERM restait sans effet
# (Échap/q jamais retirés) ; `wait`, lui, est interrompu par le signal.
wait $!
