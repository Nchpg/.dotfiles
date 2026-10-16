# shellcheck shell=bash disable=SC2034 # couleurs : lues par les scripts qui sourcent ce fichier
C_ACCENT="${DOTS_COLOR_ACCENT:-4}"
C_OK="${DOTS_COLOR_OK:-2}"
C_WARN="${DOTS_COLOR_WARN:-3}"
C_ERR="${DOTS_COLOR_ERR:-1}"
C_DIM="${DOTS_COLOR_DIM:-8}"
C_TEXT="${DOTS_COLOR_TEXT:-7}"
C_BASE="${DOTS_COLOR_BASE:-0}"

: "${GUM_CHOOSE_CURSOR_FOREGROUND:=$C_ACCENT}" "${GUM_CHOOSE_HEADER_FOREGROUND:=$C_ACCENT}"
: "${GUM_CHOOSE_SELECTED_FOREGROUND:=$C_OK}" "${GUM_CHOOSE_ITEM_FOREGROUND:=$C_TEXT}"
: "${GUM_INPUT_PROMPT_FOREGROUND:=$C_ACCENT}" "${GUM_INPUT_HEADER_FOREGROUND:=$C_ACCENT}"
: "${GUM_INPUT_CURSOR_FOREGROUND:=$C_ACCENT}" "${GUM_INPUT_PLACEHOLDER_FOREGROUND:=$C_DIM}"
: "${GUM_CONFIRM_PROMPT_FOREGROUND:=$C_ACCENT}"
: "${GUM_CONFIRM_SELECTED_BACKGROUND:=$C_ACCENT}" "${GUM_CONFIRM_SELECTED_FOREGROUND:=$C_BASE}"
: "${GUM_CONFIRM_UNSELECTED_BACKGROUND:=$C_DIM}" "${GUM_CONFIRM_UNSELECTED_FOREGROUND:=$C_TEXT}"
: "${GUM_SPIN_SPINNER_FOREGROUND:=$C_ACCENT}"
export GUM_CHOOSE_CURSOR_FOREGROUND GUM_CHOOSE_HEADER_FOREGROUND GUM_CHOOSE_SELECTED_FOREGROUND \
    GUM_CHOOSE_ITEM_FOREGROUND GUM_INPUT_PROMPT_FOREGROUND GUM_INPUT_HEADER_FOREGROUND \
    GUM_INPUT_CURSOR_FOREGROUND GUM_INPUT_PLACEHOLDER_FOREGROUND GUM_CONFIRM_PROMPT_FOREGROUND \
    GUM_CONFIRM_SELECTED_BACKGROUND GUM_CONFIRM_SELECTED_FOREGROUND \
    GUM_CONFIRM_UNSELECTED_BACKGROUND GUM_CONFIRM_UNSELECTED_FOREGROUND GUM_SPIN_SPINNER_FOREGROUND

fg() {
    case "$1" in
        \#*)
            local h="${1#\#}"
            printf '\033[38;2;%d;%d;%dm' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}"
            ;;
        *) printf '\033[38;5;%sm' "$1" ;;
    esac
}

if [ -t 1 ]; then
    R=$'\033[0m'
    B=$'\033[1m'
    OK="$(fg "$C_OK")" WARN="$(fg "$C_WARN")" ERR="$(fg "$C_ERR")"
    DIM="$(fg "$C_DIM")" ACC="$(fg "$C_ACCENT")" TXT="$(fg "$C_TEXT")"
else
    R="" B="" OK="" WARN="" ERR="" DIM="" ACC="" TXT=""
fi

ok()   { printf '%s✓%s %s\n' "$OK" "$R" "$*"; }
warn() { printf '%s%s%s\n' "$WARN" "$*" "$R" >&2; }
err()  { printf '%s%s%s\n' "$ERR" "$*" "$R" >&2; }
die()  { printf '%s✗%s %s\n' "$ERR" "$R" "$*" >&2; exit 1; }

link() {
    if [ -n "$2" ] && [ -t 1 ]; then
        # shellcheck disable=SC1003 # ESC \ (fin de séquence OSC), pas un échappement de quote
        printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$2" "$1"
    else
        printf '%s' "$1"
    fi
}

# Fonction : init.sh ne récupère gum qu'après avoir sourcé ce fichier.
ui_fancy() {
    [ -t 0 ] && [ -t 1 ] && command -v gum >/dev/null 2>&1
}

# Échap/Ctrl-C dans gum : abandon du script ici, pour ne pas confondre « non » et « abandon ».
confirm() {
    local question="$1" default="${2:-no}" rc=0 reply
    if ui_fancy; then
        gum confirm "$question" --default="$([ "$default" = yes ] && echo true || echo false)" || rc=$?
        [ "$rc" -le 1 ] || die "abandon."
        return "$rc"
    fi
    if [ "$default" = yes ]; then
        read -r -n 1 -p "$question [Y/n] " reply || reply=""
        echo
        [[ ! "$reply" =~ ^[Nn]$ ]]
    else
        read -r -n 1 -p "$question [y/N] " reply || reply=""
        echo
        [[ "$reply" =~ ^[YyOo]$ ]]
    fi
}
