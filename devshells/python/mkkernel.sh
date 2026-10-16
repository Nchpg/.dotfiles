#!/usr/bin/env bash
set -euo pipefail

if [ -z "${VIRTUAL_ENV:-}" ]; then
  echo "⚠️ Active d'abord un venv : le kernel doit pointer sur son python." >&2
  exit 1
fi

KERNEL_NAME="${1:-}"
if [ -z "$KERNEL_NAME" ]; then
  KERNEL_NAME="$(basename "$(dirname "$VIRTUAL_ENV")")"
  echo "ℹ️ Pas de nom donné → '$KERNEL_NAME' (usage : mkkernel <nom>)"
fi
# ipykernel force les minuscules.
KERNEL_NAME="${KERNEL_NAME,,}"

if ! python -c "import ipykernel" 2>/dev/null; then
  echo "📦 ipykernel absent du venv → installation via uv…"
  uv pip install ipykernel
fi

python -m ipykernel install --user --name="$KERNEL_NAME" --display-name="Python ($KERNEL_NAME)"

# Le serveur Jupyter tourne souvent hors du devshell : env runtime figé dans le kernelspec.
KDIR="$HOME/.local/share/jupyter/kernels/$KERNEL_NAME"
export _KERNEL_LD_LIBRARY_PATH="$VIRTUAL_ENV/lib:${LD_LIBRARY_PATH:-}"
# ZE_* / ONEAPI_* n'existent que dans le devshell xpu (set -u).
for var in _KERNEL_LD_LIBRARY_PATH ZE_ENABLE_ALT_DRIVERS ONEAPI_DEVICE_SELECTOR; do
  val="${!var-}"
  [ -n "$val" ] || continue
  jq --arg k "${var#_KERNEL_}" --arg v "$val" '.env = (.env // {}) + { ($k): $v }' \
    "$KDIR/kernel.json" > "$KDIR/kernel.json.tmp"
  mv "$KDIR/kernel.json.tmp" "$KDIR/kernel.json"
done

echo "✔️ Kernel '$KERNEL_NAME' créé (env runtime figé dans le kernelspec)."
