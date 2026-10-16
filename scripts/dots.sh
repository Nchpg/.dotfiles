#!/usr/bin/env bash
set -euo pipefail

here="$(dirname "$0")"
# shellcheck source=scripts/lib/env.sh
. "$here/lib/env.sh"
# shellcheck source=scripts/lib/ui.sh
. "$here/lib/ui.sh"
# shellcheck source=scripts/lib/hooks.sh
. "$here/lib/hooks.sh"

catalog="$(grep -v '^#' "$here/commands.tsv")"

hooks=0
if hooks_present "$flake"; then hooks=1; fi

names=()
while IFS=$'\t' read -r kind name _; do
  [ "$kind" = cmd ] || continue
  if [ "$name" = init ]; then
    [ -x "$flake/init.sh" ] && names+=("$name")
  elif command -v "$name" > /dev/null; then
    names+=("$name")
  fi
done <<< "$catalog"

run() {
  if [ "$1" = init ]; then
    shift
    exec "$flake/init.sh" "$@"
  fi
  exec "$@"
}

# printf compte les octets, ${#} les caractères.
pad() { printf '%s%*s' "$1" $(($2 - ${#1})) ""; }

known() {
  local n
  for n in "${names[@]}"; do [ "$n" = "$1" ] && return 0; done
  return 1
}

usage() {
  echo "usage: dots                   menu interactif"
  echo "       dots <commande> [args] lance la commande"
  echo "       dots help               cette aide"
  while IFS=$'\t' read -r kind name a b; do
    known "$name" || continue
    if [ "$kind" = cmd ]; then
      printf '\n  %s — %s\n' "$name" "$a"
    else
      printf '    %s %s\n' "$(pad "$a" 26)" "$b"
    fi
  done <<< "$catalog"
  echo
  echo "Chaque commande a aussi son propre --help (theme : sans argument = galerie)."
  if [ "$hooks" = 1 ]; then
    echo
    hooks_status "$flake"
    if ! hooks_on "$flake"; then
      echo "  pour les activer : git -C $flake config core.hooksPath .githooks"
    fi
  fi
}

case "${1:-}" in
  "") ;;
  -h | --help | help) usage; exit 0 ;;
  *)
    if known "$1"; then run "$@"; fi
    echo "dots : commande inconnue « $1 »" >&2
    echo "  dots help pour la liste" >&2
    exit 1
    ;;
esac

if [ ! -t 0 ] || [ ! -t 1 ]; then usage; exit 0; fi

# Dans pick(), `|| bye` ne quitterait que le sous-shell : il reste à l'appel.
pick() { gum choose --label-delimiter=$'\t' "$@"; }

# gum écrit « nothing selected » sur stderr (non muet) : on efface la ligne.
bye() { printf '\e[1A\e[2K' >&2; exit 0; }

if [ "$hooks" = 1 ]; then
  if hooks_on "$flake"; then hooks_status "$flake"; else hooks_offer "$flake"; fi
  echo
fi

opts=()
while IFS=$'\t' read -r kind name desc _; do
  if [ "$kind" != cmd ] || ! known "$name"; then continue; fi
  opts+=("$(printf '%-10s %s' "$name" "$desc")"$'\t'"$name")
done <<< "$catalog"
cmd=$(pick --header "Quelle commande ?" "${opts[@]}") || bye

opts=()
while IFS=$'\t' read -r kind name line expl; do
  if [ "$kind" != ex ] || [ "$name" != "$cmd" ]; then continue; fi
  opts+=("$(pad "$line" 26) $expl"$'\t'"$line")
done <<< "$catalog"
opts+=("✎ autre… (arguments libres)"$'\t'"__custom__")
line=$(pick --header "$cmd — quel usage ?" "${opts[@]}") || bye

if [ "$line" = __custom__ ]; then
  line=$(gum input --header "Arguments ($cmd --help pour la liste)" --value "$cmd ") || bye
fi

while [[ "$line" =~ \<([^>]+)\> ]]; do
  hole="${BASH_REMATCH[0]}"
  value=$(gum input --header "$line" --placeholder "${BASH_REMATCH[1]}") || bye
  [ -n "$value" ] || { echo "dots : valeur vide, abandon." >&2; exit 1; }
  line="${line/"$hole"/"$value"}"
done

read -ra argv <<< "$line"
known "${argv[0]:-}" || { echo "dots : commande inconnue « ${argv[0]:-} »" >&2; exit 1; }

echo "→ $line"
run "${argv[@]}"
