[[ $- != *i* ]] && return

parse_git_branch() {
  local head_file="$PWD/.git/HEAD"
  if [[ -r "$head_file" ]]; then
    local branch
    branch=$(sed -n 's|ref: refs/heads/||p' "$head_file")
    [[ -n "$branch" ]] && echo "\[\e[91m\] $branch\[\e[0m\]"
  fi
}

HISTCONTROL=ignoreboth
HISTSIZE=6000
HISTFILESIZE=6000
shopt -s histappend
shopt -s checkwinsize

if [ "$SHLVL" -eq 1 ]; then
    FIRST_PROMPT=1
else
    FIRST_PROMPT=0
fi
# Fonction pour construire le prompt avec l'heure alignée à droite
set_bash_prompt() {
    local last_status=$?
    local user_host="\[\e[0;36m\]\u@\h\[\e[0m\]"
    local cwd="\[\e[0;34m\]\w\[\e[0m\]"
    local git_branch="\[\e[91m\]$(parse_git_branch)\[\e[0m\]"
    local status=""
    [ $last_status -ne 0 ] && status="\[\e[91m\]✘$last_status \[\e[0m\]"
    
    # Heure
    local time="\[\e[33m\]\t\[\e[0m\]"

    # Calcul de la longueur du prompt pour aligner l'heure à droite
    local cols=$(tput cols)
    # Prompt sans l'heure
    local left_prompt="$user_host $cwd $git_branch"
    # Retirer les séquences ANSI pour calculer la longueur
    #local clean_left=$(echo -e "$left_prompt" | sed 's/\x1b\[[0-9;]*m//g')
    #local padding=$((cols - ${#clean_left}))
    #[ $padding -lt 1 ] && padding=1

    if [ "$FIRST_PROMPT" -eq 1 ]; then
        NEW_LINE=""
        FIRST_PROMPT=0
    else
        NEW_LINE="\n"
    fi

    if [ "$SHLVL" -gt 1 ]; then
        SHELL_DEPTH="$SHLVL"
    else
        SHELL_DEPTH=""
    fi

    # Construire la ligne finale
    #PS1="$NEW_LINE$left_prompt$(printf '%*s' "$padding")$time\n$status\[\e[0;32m\]$SHELL_DEPTH❯ \[\e[0m\]"
    PS1="$NEW_LINE$left_prompt\n$status\[\e[0;32m\]$SHELL_DEPTH❯ \[\e[0m\]"
}

clear() {
    command clear
    FIRST_PROMPT=1
}

nix-shell() {
    for arg in "$@"; do
        if [ "$arg" = "--run" ]; then
            command nix-shell "$@"
            return
        fi
    done

    command nix-shell "$@" --run "exec bash"
}

PROMPT_COMMAND=set_bash_prompt