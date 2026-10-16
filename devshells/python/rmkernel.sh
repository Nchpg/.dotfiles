#!/usr/bin/env bash
set -euo pipefail

KERNEL_NAME="${1:-}"
if [ -z "$KERNEL_NAME" ]; then
  echo "Usage : rmkernel <nom>   (tab pour compléter)" >&2
  echo "Kernels installés :" >&2
  find "$HOME/.local/share/jupyter/kernels" -mindepth 1 -maxdepth 1 -printf '  - %f\n' 2>/dev/null >&2
  exit 1
fi
KERNEL_NAME="${KERNEL_NAME,,}"

# Sous sudo, $HOME vaut /root : viser le home de l'utilisateur d'origine.
USER_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
KDIR="${USER_HOME:-$HOME}/.local/share/jupyter/kernels/$KERNEL_NAME"

if [ ! -d "$KDIR" ]; then
  echo "⚠️ Kernel '$KERNEL_NAME' introuvable dans $KDIR." >&2
  exit 1
fi

if rm -rf "$KDIR" 2>/dev/null; then
  echo "✔️ Kernel '$KERNEL_NAME' supprimé."
else
  echo "⚠️ Échec (fichiers appartenant à root ?) → réessaie : sudo rmkernel" >&2
  exit 1
fi
