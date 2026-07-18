#!/usr/bin/env bash
set -euo pipefail

KERNEL_NAME="${1:-}"
if [ -z "$KERNEL_NAME" ]; then
  echo "Usage : rmkernel <nom>   (tab pour compléter)" >&2
  echo "Kernels installés :" >&2
  ls -1 "$HOME/.local/share/jupyter/kernels" 2>/dev/null | sed 's/^/  - /' >&2
  exit 1
fi
# ipykernel installe en minuscules — accepter n'importe quelle casse.
KERNEL_NAME="${KERNEL_NAME,,}"

# Sous sudo, $HOME devient /root : viser le home de l'utilisateur d'origine
# pour que `sudo rmkernel` supprime bien SES kernels (utile pour les vieux
# kernels créés en root, ex. l'ère Docker).
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
