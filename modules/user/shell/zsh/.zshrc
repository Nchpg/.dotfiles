# NIXOS BASE ZSH

typeset -U path cdpath fpath manpath
for profile in ${(z)NIX_PROFILES}; do
  fpath+=($profile/share/zsh/site-functions $profile/share/zsh/$ZSH_VERSION/functions $profile/share/zsh/vendor-completions)
done

autoload -U compinit && compinit
HISTSIZE="10000"
SAVEHIST="10000"
HISTFILE="$HOME/.zsh_history"
mkdir -p "$(dirname "$HISTFILE")"

setopt HIST_FCNTL_LOCK
unsetopt APPEND_HISTORY
setopt HIST_IGNORE_DUPS
unsetopt HIST_IGNORE_ALL_DUPS
unsetopt HIST_SAVE_NO_DUPS
unsetopt HIST_FIND_NO_DUPS
setopt HIST_IGNORE_SPACE
unsetopt HIST_EXPIRE_DUPS_FIRST
setopt SHARE_HISTORY
setopt EXTENDED_HISTORY


if test -n "$KITTY_INSTALLATION_DIR"; then
  export KITTY_SHELL_INTEGRATION="no-rc"
  autoload -Uz -- "$KITTY_INSTALLATION_DIR"/shell-integration/zsh/kitty-integration
  kitty-integration
  unfunction kitty-integration
fi

# CUSTOM CONFIG

export LS_COLORS="di=0;34:ln=0;36:ex=0;32:*.tar=0;31:*.zip=0;31"

alias ls='ls --color=auto'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias ll='eza -lha --icons=auto  --sort=name --group-directories-first'

alias su='sudo su -s "$0"'
alias cat="bat --paging=never"
alias cls="clear"

export EDITOR=vim
export VISUAL=vim

autoload -Uz colors && colors
autoload -Uz compinit && compinit
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
setopt PROMPT_SUBST   # allow command substitution in PROMPT

setopt NO_BEEP

# PS1

git_branch() {
  local head_file="$PWD/.git/HEAD"
  if [[ -r "$head_file" ]]; then
    local branch
    branch=$(sed -n 's|ref: refs/heads/||p' "$head_file")
    [[ -n "$branch" ]] && echo "%F{red} ${branch}%f"
  fi
}

if [ "$SHLVL" -eq 1 ]; then
    FIRST_PROMPT=1
else
    FIRST_PROMPT=0
fi

# Fonction pour construire le prompt
build_prompt() {
  local left_prompt="%F{cyan}%n@%m%f %F{blue}%~%f $(git_branch)"
  local last_status=""

  # Code de sortie de la dernière commande
  if [[ $? -ne 0 ]]; then
    last_status="%F{red}✘$?%f "
  fi

  # Retour à la ligne seulement si ce n'est pas le premier prompt
  local new_line=""
  if [[ $FIRST_PROMPT -eq 0 ]]; then
    new_line="
"
  fi

  FIRST_PROMPT=0

  if [ "$SHLVL" -gt 1 ]; then
    SHELL_DEPTH="$SHLVL"
  else
    SHELL_DEPTH=""
  fi

  # Prompt principal (deux lignes)
  PROMPT="${new_line}${left_prompt}
${last_status}%F{green}$SHELL_DEPTH❯%f "

  # Heure à droite
  RPROMPT="%F{yellow}%*%f"
}

# Lancer la construction du prompt avant chaque commande
precmd_functions+=(build_prompt)

# Alias cls pour clear + reset FIRST_PROMPT
clear() {
    command clear
    FIRST_PROMPT=1
}

nix-shell() {
    local has_run=0
    for arg in "$@"; do
        if [ "$arg" = "--run" ]; then
            has_run=1
            break
        fi
    done

    if [ $has_run -eq 1 ]; then
        command nix-shell "$@"
    else
        command nix-shell "$@" --run "exec zsh"
    fi
}

# bindkey '^?' delete-char
bindkey '^[[3~' delete-char