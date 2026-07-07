_rmkernel_complete() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  COMPREPLY=( $(compgen -W "$(command ls -1 "$HOME/.local/share/jupyter/kernels" 2>/dev/null)" -- "$cur") )
}
complete -F _rmkernel_complete rmkernel
