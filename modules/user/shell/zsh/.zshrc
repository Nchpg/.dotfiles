# BASE CONFIG

typeset -U path cdpath fpath manpath
for profile in ${(z)NIX_PROFILES}; do
  fpath+=($profile/share/zsh/site-functions $profile/share/zsh/$ZSH_VERSION/functions $profile/share/zsh/vendor-completions)
done

HISTSIZE="10000"
SAVEHIST="10000"
HISTFILE="$HOME/.zsh_history"
mkdir -p "$(dirname "$HISTFILE")"

setopt HIST_FCNTL_LOCK
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE
setopt SHARE_HISTORY
setopt EXTENDED_HISTORY
unsetopt APPEND_HISTORY
unsetopt HIST_IGNORE_ALL_DUPS
unsetopt HIST_SAVE_NO_DUPS
unsetopt HIST_FIND_NO_DUPS
unsetopt HIST_EXPIRE_DUPS_FIRST

if test -n "$KITTY_INSTALLATION_DIR"; then
  export KITTY_SHELL_INTEGRATION="no-rc"
  autoload -Uz -- "$KITTY_INSTALLATION_DIR"/shell-integration/zsh/kitty-integration
  kitty-integration
  unfunction kitty-integration
fi

autoload -Uz colors && colors
autoload -Uz compinit && compinit
setopt PROMPT_SUBST
setopt NO_BEEP

# CUSTOM CONFIG

# PS1

export SH=zsh

# FIRST_PROMPT, clear(), setdev() : cf. ../common-posix (partagé avec bash,
# injecté par shell/zsh/default.nix).

# On interroge git plutôt que de lire $PWD/.git/HEAD : ce dernier n'existe
# qu'à la racine du dépôt (aucune branche affichée dans un sous-dossier) et
# n'est même pas un dossier sur un worktree ou un submodule.
git_branch() {
  local branch
  branch=$(git symbolic-ref --short HEAD 2>/dev/null) \
    || branch=$(git rev-parse --short HEAD 2>/dev/null) \
    || return
  [[ -n "$branch" ]] && echo "%F{red} ${branch}%f"
}

# Fonction pour construire le prompt
build_prompt() {
  # DOIT rester la toute première instruction : $? porte le code de sortie de
  # la commande de l'utilisateur, et n'importe quelle commande intermédiaire
  # (jusqu'à une simple affectation) l'écrase.
  local last_status=$?

  venv_name=""

  if [[ -n "$VIRTUAL_ENV" ]]; then
    venv_name="($(basename "$(dirname "$VIRTUAL_ENV")")/$(basename "$VIRTUAL_ENV")) "
  elif [[ -n "$NIX_DEV_SHELL_PYTHON" ]]; then
    venv_name="($NIX_DEV_SHELL_PYTHON) "
  fi

  for var in ${(k)parameters}; do
    [[ $var == NIX_DEV_SHELL_* ]] || continue
    [[ $var == NIX_DEV_SHELL_PYTHON ]] && continue

    current=${(P)var}
    venv_name="${venv_name}($current) "
  done

  venv_name="%F{yellow}$venv_name%f"

  local left_prompt="%F{cyan}%n@%m%f %F{blue}%~%f ${venv_name}$(git_branch)"

  # Code de sortie de la dernière commande (capturé en tête de fonction).
  local status_prompt=""
  if [[ $last_status -ne 0 ]]; then
    status_prompt="%F{red}✘${last_status}%f "
  fi

  # Retour à la ligne seulement si ce n'est pas le premier prompt
  local new_line=""
  if [[ $FIRST_PROMPT -eq 0 ]]; then
    new_line="
"
  fi

  FIRST_PROMPT=0

  if [ "$TERM_PROGRAM" = "vscode" ]; then
    SHELL_DEPTH=$((SHLVL - 1))
  else
    SHELL_DEPTH="$SHLVL"
  fi

  if [ "$SHELL_DEPTH" -le 1 ]; then
    SHELL_DEPTH=""
  fi

  # Prompt principal (deux lignes)
  PROMPT="${new_line}${left_prompt}
${status_prompt}%F{green}$SHELL_DEPTH❯%f "
}

# Lancer la construction du prompt avant chaque commande
precmd_functions+=(build_prompt)

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

nix() {
  if [[ "$1" == "develop" ]]; then
    if [[ " $* " == *" --command "* ]]; then
      command nix "$@"
    else
      command nix develop "${@:2}" --command zsh
    fi
  else
    command nix "$@"
  fi
}

# Complétions fournies par un devshell (ex. rmkernel dans devshells/python.nix).
# Équivalent de NIX_DEVSHELL_FISH_COMPLETIONS côté fish.
if [[ -n "$NIX_DEVSHELL_ZSH_COMPLETIONS" ]]; then
  fpath=($NIX_DEVSHELL_ZSH_COMPLETIONS $fpath)
  for f in $NIX_DEVSHELL_ZSH_COMPLETIONS/_*(N:t); do
    autoload -Uz $f
    compdef $f ${f#_}
  done
fi

# bindkey '^?' delete-char
bindkey '^[[3~' delete-char