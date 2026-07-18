#!/usr/bin/env bash
set -euo pipefail

# Le kernel doit pointer sur le python du venv (c'est lui qui a torch & co),
# pas sur le python nix nu du devshell.
if [ -z "${VIRTUAL_ENV:-}" ]; then
  echo "⚠️ Active d'abord un venv : le kernel doit pointer sur son python." >&2
  exit 1
fi

# Nom en argument ; défaut = nom du dossier projet contenant le venv.
KERNEL_NAME="${1:-}"
if [ -z "$KERNEL_NAME" ]; then
  KERNEL_NAME="$(basename "$(dirname "$VIRTUAL_ENV")")"
  echo "ℹ️ Pas de nom donné → '$KERNEL_NAME' (usage : mkkernel <nom>)"
fi
# ipykernel force les noms en minuscules — on s'aligne, sinon le patch d'env
# ci-dessous viserait un dossier inexistant.
KERNEL_NAME="${KERNEL_NAME,,}"

if ! python -c "import ipykernel" 2>/dev/null; then
  echo "📦 ipykernel absent du venv → installation via uv…"
  uv pip install ipykernel
fi

python -m ipykernel install --user --name="$KERNEL_NAME" --display-name="Python ($KERNEL_NAME)"

# Le serveur Jupyter tourne souvent HORS du devshell : on fige dans le
# kernelspec l'env runtime (libs nix, driver Level-Zero pour le shell xpu)
# pour que le kernel marche partout. À refaire (mkkernel) si ces chemins
# /nix/store changent après un rebuild.
KDIR="$HOME/.local/share/jupyter/kernels/$KERNEL_NAME"
export _KERNEL_LD_LIBRARY_PATH="$VIRTUAL_ENV/lib:${LD_LIBRARY_PATH:-}"
# ZE_* / ONEAPI_* ne sont posées que par le devshell xpu : sous `set -u`,
# l'expansion indirecte doit tolérer une variable absente (sinon mkkernel
# avorte dans le devshell python, après avoir déjà créé le kernelspec).
for var in _KERNEL_LD_LIBRARY_PATH ZE_ENABLE_ALT_DRIVERS ONEAPI_DEVICE_SELECTOR; do
  val="${!var-}"
  [ -n "$val" ] || continue
  jq --arg k "${var#_KERNEL_}" --arg v "$val" '.env = (.env // {}) + { ($k): $v }' \
    "$KDIR/kernel.json" > "$KDIR/kernel.json.tmp"
  mv "$KDIR/kernel.json.tmp" "$KDIR/kernel.json"
done

echo "✔️ Kernel '$KERNEL_NAME' créé (env runtime figé dans le kernelspec)."
