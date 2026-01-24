[[ $- != *i* ]] && return

parse_git_branch() {
  local head_file="$PWD/.git/HEAD"
  if [[ -r "$head_file" ]]; then
    local branch
    branch=$(sed -n 's|ref: refs/heads/||p' "$head_file")
    [[ -n "$branch" ]] && echo "\[\e[31m\] $branch\[\e[0m\]"
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
    local git_branch="\[\e[31m\]$(parse_git_branch)\[\e[0m\]"
    local status=""
    [ $last_status -ne 0 ] && status="\[\e[31m\]✘$last_status \[\e[0m\]"

        # Afficher le venv si actif
    local venv=""
    if [[ -n "$VIRTUAL_ENV" ]]; then
        venv="\[\e[33m\](\$(basename \"$VIRTUAL_ENV\"))\[\e[0m\] "
    fi
    
    if [ "$FIRST_PROMPT" -eq 1 ]; then
        NEW_LINE=""
        FIRST_PROMPT=0
    else
        NEW_LINE="\n"
    fi

    if [ "$TERM_PROGRAM" = "vscode" ]; then
        SHELL_DEPTH=$((SHLVL - 1))
    else
        SHELL_DEPTH="$SHLVL"
    fi

    if [ "$SHELL_DEPTH" -le 1 ]; then
        SHELL_DEPTH=""
    fi

    # Construire la ligne finale
    PS1="$NEW_LINE$user_host $cwd $venv$git_branch\n$status\[\e[0;32m\]$SHELL_DEPTH❯ \[\e[0m\]"
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

nix() {
  if [[ "$1" == "develop" ]]; then
    if [[ " $* " == *" --command "* ]]; then
      command nix "$@"
    else
      command nix develop "${@:2}" --command bash
    fi
  else
    command nix "$@"
  fi
}


PROMPT_COMMAND=set_bash_prompt