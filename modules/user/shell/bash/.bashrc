parse_git_branch() {
  local head_file="$PWD/.git/HEAD"
  if [[ -r "$head_file" ]]; then
    local branch
    branch=$(sed -n 's|ref: refs/heads/||p' "$head_file")
    [[ -n "$branch" ]] && echo "\[\e[91m\] $branch\[\e[0m\]"
  fi
}


# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

HISTCONTROL=ignoreboth
HISTSIZE=6000
HISTFILESIZE=6000
shopt -s histappend
shopt -s checkwinsize


alias ls='eza --icons=auto'
alias ll='eza -lha --icons=auto --sort=name --group-directories-first'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'
alias la='ls -A'
alias l='ls -CF'
alias cls="clear"
alias su='sudo su -s "$0"'
alias cat="bat --paging=never"

export EDITOR=vim
export VISUAL=vim


#PS1='\n${debian_chroot:+($debian_chroot)}\[\e[0;36m\][\t]\[\e[0;m\] ${os_space}\[\e[0;32m\]Nchpg\[\e[0;m\]: \[\033[01;34m\]\w\[\033[00m\] \[\e[38;2;255;107;129m\]$(parse_git_branch)\[\e[00m\]$ '

#PS1='\n$(if [ $? = 0 ]; then echo -n "[\e[0;32m][$?]"; else echo -n "[\e[07;91m][$?][\e[0m]"; fi) [\e[0;36m][\t] [\e[01;35m]\u[\e[01;37m]@[\e[01;35m]\h[\e[0;m]: [\e[01;34m]\w [\e[91m]$(parse_git_branch)[\e[0m]\n$ '

# Prompt principal sur deux lignes
# PS1='\n\[\e[0;36m\]\u@\h\[\e[0m\] \[\e[0;34m\]\w\[\e[0m\] $(parse_git_branch)
# \[\e[0;32m\]❯ \[\e[0m\]'

# # Afficher le statut de la dernière commande
# PROMPT_COMMAND='LAST_STATUS=$?; PS1="\n\[\e[0;36m\]\u@\h\[\e[0m\] \[\e[0;34m\]\w\[\e[0m\] $(parse_git_branch)
# $(if [ $LAST_STATUS -ne 0 ]; then echo -e "\[\e[91m\]✘$LAST_STATUS \[\e[0m\]"; fi)\[\e[0;32m\]❯ \[\e[0m\]"'

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
    local clean_left=$(echo -e "$left_prompt" | sed 's/\x1b\[[0-9;]*m//g')
    local padding=$((cols - ${#clean_left}))
    [ $padding -lt 1 ] && padding=1

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
    PS1="$NEW_LINE$left_prompt$(printf '%*s' "$padding")$time\n$status\[\e[0;32m\]$SHELL_DEPTH❯ \[\e[0m\]"
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

# Preserve the default prompt in Nix shell
export NIX_SHELL_PRESERVE_PROMPT=1