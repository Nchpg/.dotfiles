# Pas de garde d'interactivité : home-manager injecte ce fichier en tête du .bashrc.

# git plutôt que $PWD/.git/HEAD (absent en sous-dossier, worktree ou submodule).
parse_git_branch() {
  local branch
  branch=$(git symbolic-ref --short HEAD 2>/dev/null) \
    || branch=$(git rev-parse --short HEAD 2>/dev/null) \
    || return
  [[ -n "$branch" ]] && echo "\[\e[31m\] $branch\[\e[0m\]"
}

shopt -s checkwinsize

export SH=bash

set_bash_prompt() {
    local last_status=$?
    local user_host="\[\e[0;36m\]\u@\h\[\e[0m\]"
    local cwd="\[\e[0;34m\]\w\[\e[0m\]"
    local git_branch
    git_branch="$(parse_git_branch)"
    local status=""
    [ $last_status -ne 0 ] && status="\[\e[31m\]✘$last_status \[\e[0m\]"

    venv_name=""

    if [ -n "$VIRTUAL_ENV" ]; then
        venv_name="($(basename "$(dirname "$VIRTUAL_ENV")")/$(basename "$VIRTUAL_ENV")) "
    elif [ -n "$NIX_DEV_SHELL_PYTHON" ]; then
        venv_name="($NIX_DEV_SHELL_PYTHON) "
    fi

    for var in ${!NIX_DEV_SHELL_*}; do
        if [ "$var" = "NIX_DEV_SHELL_PYTHON" ]; then
            continue
        fi

        current="${!var}"
        venv_name="${venv_name}($current) "
    done

    # Les \[ \] évitent que bash compte les octets ANSI dans la largeur du prompt.
    venv_name="\[\e[33m\]$venv_name\[\e[0m\]"

    if [ "$FIRST_PROMPT" -eq 1 ]; then
        NEW_LINE=""
        FIRST_PROMPT=0
    else
        NEW_LINE="\n"
    fi

    local depth=""
    [ "$SHELL_DEPTH" -gt 1 ] && depth=$SHELL_DEPTH

    PS1="$NEW_LINE$user_host $cwd $venv_name$git_branch\n$status\[\e[0;32m\]$depth❯ \[\e[0m\]"
}

PROMPT_COMMAND=set_bash_prompt