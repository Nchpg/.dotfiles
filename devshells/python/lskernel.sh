#!/usr/bin/env bash

for spec in "$HOME/.local/share/jupyter/kernels"/*/kernel.json; do
  [ -f "$spec" ] || continue
  dir=$(dirname "$spec")
  printf '%s\t%s\t%s\n' "$(basename "$dir")" "$(jq -r '.argv[0]' "$spec")" "$dir"
done | column -t
