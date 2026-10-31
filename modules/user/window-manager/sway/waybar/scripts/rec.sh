#!/usr/bin/env bash
set -euo pipefail
# Enregistrement d'écran (screenrec, cf. gui/wf-recorder) : durée écoulée pendant la capture,
# puis le chemin du fichier sauvegardé quelques secondes, masqué sinon. screenrec écrit
# « epoch chemin » dans $XDG_RUNTIME_DIR/screenrec/last en fin de capture.
# « click » : arrête l'enregistrement (SIGINT, sinon le mp4 sort sans index) ; une fois
# sauvegardé, ouvre « Enregistrer sous » pour déplacer ou renommer le fichier.

export LC_ALL=C

shown_for=10 # secondes d'affichage du chemin
state_dir="${XDG_RUNTIME_DIR:-/tmp}/screenrec"
last="$state_dir/last"

start="$state_dir/start"

# md-content-save, une disquette (U+F0193), écrite en octets UTF-8 : sous LC_ALL=C, bash ne
# convertit pas \U. Un ✔ passerait par la police d'emoji de waybar, qui ignore la couleur
# du CSS ; ce glyphe vient de la Nerd Font et prend le vert.
saved=$'\xf3\xb0\x86\x93'

move_recording() {
    local ts path dest
    if [ ! -r "$last" ]; then
        return 0
    fi
    read -r ts path <"$last"
    if [ ! -f "$path" ]; then
        rm -f "$last"
        return 0
    fi

    # Un seul dialogue à la fois, même si on clique plusieurs fois.
    exec 9>"$state_dir/move.lock"
    if ! flock -n 9; then
        return 0
    fi

    # Annuler masque le chemin : on ne veut pas le déplacer.
    if ! dest=$(zenity --file-selection --save --confirm-overwrite \
        --title="Enregistrer l'enregistrement sous" --filename="$path"); then
        rm -f "$last"
        return 0
    fi
    if [[ ${dest##*/} != *.* ]]; then
        dest+=.mp4
    fi

    if [ "$dest" != "$path" ]; then
        if ! mv -- "$path" "$dest"; then
            zenity --error --text="Déplacement impossible vers $dest" || true
            return 0
        fi
    fi

    # Le presse-papiers et le chemin affiché suivent le fichier.
    printf '%s' "$dest" | wl-copy
    printf '%s %s\n' "$(date +%s)" "$dest" >"$last"
}

if [ "${1:-}" = click ]; then
    if pkill -INT -x wf-recorder; then
        exit 0
    fi
    move_recording
    exit 0
fi

# « pid heure_de_départ_en_µs » écrit par screenrec juste avant la capture ; sinon (wf-recorder
# lancé à la main) l'âge du processus.
secs=""
if [ -r "$start" ] && read -r spid start_us <"$start" && [[ $start_us =~ ^[0-9]+$ ]] \
    && kill -0 "$spid" 2>/dev/null; then
    now_us=${EPOCHREALTIME/./}
    secs=$(((now_us - start_us) / 1000000))
elif pid=$(pgrep -x wf-recorder | head -n1) && [ -n "$pid" ]; then
    secs=$(ps -o etimes= -p "$pid" | tr -d ' ') || secs=0
fi
if [ -n "$secs" ]; then
    if [ "$secs" -ge 3600 ]; then
        printf -v elapsed '%d:%02d:%02d' $((secs / 3600)) $((secs % 3600 / 60)) $((secs % 60))
    else
        printf -v elapsed '%02d:%02d' $((secs / 60)) $((secs % 60))
    fi
    tip="Enregistrement d'écran en cours : $elapsed"
    tip+=$'\n'
    tip+=$'\n'"Clic : arrêter et sauvegarder"
    emit "●  $elapsed" "$tip" rec
    exit 0
fi

printf -v now '%(%s)T' -1
if [ -r "$last" ] && read -r ts path <"$last" && [[ $ts =~ ^[0-9]+$ ]] && ((now - ts < shown_for)); then
    tip="Enregistrement sauvegardé :"
    tip+=$'\n'"$path"
    tip+=$'\n'
    tip+=$'\n'"Chemin copié dans le presse-papiers"
    tip+=$'\n'"Clic : déplacer ou renommer"
    emit "$saved  ${path/#"$HOME"/\~}" "$tip" "done"
    exit 0
fi

printf '{"text":""}\n'
