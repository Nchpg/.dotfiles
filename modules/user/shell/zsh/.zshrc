# Historique, path, fpath, compinit et kitty sont générés par home-manager.

autoload -Uz colors && colors
setopt PROMPT_SUBST
setopt NO_BEEP

export SH=zsh

# git plutôt que $PWD/.git/HEAD (absent en sous-dossier, worktree ou submodule).
git_branch() {
  local branch
  branch=$(git symbolic-ref --short HEAD 2>/dev/null) \
    || branch=$(git rev-parse --short HEAD 2>/dev/null) \
    || return
  [[ -n "$branch" ]] && echo "%F{red} ${branch}%f"
}

build_prompt() {
  # Doit rester la première instruction : tout écrase $?.
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

  local status_prompt=""
  if [[ $last_status -ne 0 ]]; then
    status_prompt="%F{red}✘${last_status}%f "
  fi

  local new_line=""
  if [[ $FIRST_PROMPT -eq 0 ]]; then
    new_line="
"
  fi

  FIRST_PROMPT=0

  local depth=""
  (( SHELL_DEPTH > 1 )) && depth=$SHELL_DEPTH

  PROMPT="${new_line}${left_prompt}
${status_prompt}%F{green}$depth❯%f "
}

precmd_functions+=(build_prompt)

if [[ -n "$NIX_DEVSHELL_ZSH_COMPLETIONS" ]]; then
  fpath=($NIX_DEVSHELL_ZSH_COMPLETIONS $fpath)
  for f in $NIX_DEVSHELL_ZSH_COMPLETIONS/_*(N:t); do
    autoload -Uz $f
    compdef $f ${f#_}
  done
fi

bindkey '^[[3~' delete-char