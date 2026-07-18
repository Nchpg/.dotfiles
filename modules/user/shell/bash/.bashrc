[[ $- != *i* ]] && return

# On interroge git plutôt que de lire $PWD/.git/HEAD : ce dernier n'existe
# qu'à la racine du dépôt (aucune branche affichée dans un sous-dossier) et
# n'est même pas un dossier sur un worktree ou un submodule.
parse_git_branch() {
  local branch
  branch=$(git symbolic-ref --short HEAD 2>/dev/null) \
    || branch=$(git rev-parse --short HEAD 2>/dev/null) \
    || return
  [[ -n "$branch" ]] && echo "\[\e[31m\] $branch\[\e[0m\]"
}

HISTCONTROL=ignoreboth
HISTSIZE=6000
HISTFILESIZE=6000
shopt -s histappend
shopt -s checkwinsize

export SH=bash

# FIRST_PROMPT, clear(), setdev() : cf. ../common-posix (partagé avec zsh,
# injecté par shell/bash/default.nix).

# Fonction pour construire le prompt avec l'heure alignée à droite
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

    # Couleur jaune. Les \[ \] sont indispensables : sans eux bash compte les
    # octets ANSI dans la largeur du prompt, et l'édition de ligne se décale
    # dès qu'un venv est actif.
    venv_name="\[\e[33m\]$venv_name\[\e[0m\]"

    
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
    PS1="$NEW_LINE$user_host $cwd $venv_name$git_branch\n$status\[\e[0;32m\]$SHELL_DEPTH❯ \[\e[0m\]"
}

nix-shell() {
    for arg in "$@"; do
        if [ "$arg" = "--run" ]; then
            command nix-shell "$@"
            return
        fi
    done

    command nix-shell "$@" --run "exec $SHELL"
}

nix() {
    if [ "$1" = "develop" ]; then
        # `-c` est l'abréviation de `--command` : sans ce test, `nix develop -c
        # cmd` se voyait ajouter un second `--command bash` et échouait.
        for arg in "$@"; do
            if [ "$arg" = "--command" ] || [ "$arg" = "-c" ]; then
                command nix "$@"
                return
            fi
        done
        command nix develop "${@:2}" --command bash
    else
        command nix "$@"
    fi
}

PROMPT_COMMAND=set_bash_prompt