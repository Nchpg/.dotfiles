# shellcheck shell=bash

flake="${MY_FLAKE:-}"
stateDir="${XDG_RUNTIME_DIR:-/tmp/dotstate-$(id -u)}/dotstate"
current="${DOTSTATE_CURRENT:-/run/current-system}"
booted="${DOTSTATE_BOOTED:-/run/booted-system}"
host="${HOSTNAME:-$(uname -n)}"

# `secrets` est une commande du système ; le timer tourne avec un PATH réduit.
export PATH="$PATH:$current/sw/bin"

usage() {
  cat <<'USAGE'
usage: dotstate         met à jour depuis GitHub, puis affiche l'état complet
       dotstate greet   résumé d'ouverture de shell (rien si tout est en phase)
       dotstate fetch   met à jour depuis GitHub, sans rien afficher
USAGE
}

lines=()
gitf() { git -C "$flake" "$@"; }

# Aucune invite possible : le timer n'a pas de terminal.
fetchUpstream() {
  local branch url https="" ok=1
  branch="$(gitf branch --show-current)"
  [ -n "$branch" ] || return 0
  url="$(gitf remote get-url origin 2> /dev/null)" || return 0
  case "$url" in
    git@github.com:*) https="https://github.com/${url#git@github.com:}" ;;
    ssh://git@github.com/*) https="https://github.com/${url#ssh://git@github.com/}" ;;
    https://github.com/*) https="$url" ;;
  esac
  export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=true SSH_ASKPASS="" \
    GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10"
  if timeout 20 git -C "$flake" fetch -q origin "$branch" 2> /dev/null; then
    ok=0
  elif [ -n "$https" ]; then
    if timeout 20 git -C "$flake" fetch -q --no-write-fetch-head "$https" \
      "+refs/heads/$branch:refs/remotes/origin/$branch" 2> /dev/null; then
      ok=0
    elif timeout 20 git -C "$flake" -c credential.helper= -c credential.https://github.com.helper= \
      fetch -q --no-write-fetch-head "$https" "+refs/heads/$branch:refs/remotes/origin/$branch" \
      2> /dev/null; then
      ok=0
    fi
  fi
  mkdir -p "$stateDir"
  if [ "$ok" = 0 ]; then
    rm -f "$stateDir/unreachable"
  elif [ ! -e "$stateDir/unreachable" ]; then
    date +%s > "$stateDir/unreachable"
  fi
}

# Doit rester identique au calcul de `dotfilesContent` de flake.nix.
contentOf() {
  local rev="$1" cache="$stateDir/content" tmp sum
  if [ -r "$cache" ] && [ "$(cut -d' ' -f1 "$cache")" = "$rev" ]; then
    cut -d' ' -f2 "$cache"
    return 0
  fi
  tmp="$(mktemp -d)"
  if ! gitf archive "$rev" | tar -x -C "$tmp"; then
    rm -rf "$tmp"
    return 1
  fi
  sum="$(cd "$tmp" && find . -type f -print0 | xargs -0 -r sha256sum \
    | sed -E 's|^([0-9a-f]{64})  \./(.*)$|\2 \1|' | LC_ALL=C sort | sha256sum | cut -c1-64)"
  rm -rf "$tmp"
  mkdir -p "$stateDir"
  echo "$rev $sum" > "$cache"
  echo "$sum"
}

compute() {
  local head running run dirty n ahead behind out f since deploy="" sysContent

  head="$(gitf rev-parse -q --verify HEAD)" || return 0

  dirty="$(gitf status --porcelain --untracked-files=no | wc -l)"

  running="$("$current/sw/bin/nixos-version" --configuration-revision 2> /dev/null || true)"
  if [ -z "$running" ]; then
    lines+=("révision du système inconnue (construit avant ce suivi) : rebuild pour l'activer")
  else
    run="${running%-dirty}"
    if [ "$run" != "$head" ]; then
      if gitf merge-base --is-ancestor "$run" HEAD 2> /dev/null; then
        n="$(gitf rev-list --count "$run..HEAD")"
        deploy="$n commit(s) pas encore déployé(s) : rebuild"
      elif gitf merge-base --is-ancestor HEAD "$run" 2> /dev/null; then
        n="$(gitf rev-list --count "HEAD..$run")"
        deploy="le système a $n commit(s) d'avance sur le dépôt local : git pull"
      elif gitf cat-file -e "$run^{commit}" 2> /dev/null; then
        deploy="système construit depuis une autre branche (${run:0:7}) : rebuild"
      else
        deploy="système construit depuis ${run:0:7}, inconnu ici : git pull, puis rebuild"
      fi
    elif [ "$running" != "$run" ] && [ "$dirty" = 0 ]; then
      deploy="système construit avec des modifications abandonnées depuis : rebuild"
    fi
    if [ -n "$deploy" ]; then
      sysContent="$(command cat "$current/etc/dotfiles/content" 2> /dev/null || true)"
      if [ -n "$sysContent" ] && [ "$(contentOf "$head" || true)" = "$sysContent" ]; then
        deploy=""
      fi
    fi
    if [ -n "$deploy" ]; then lines+=("$deploy"); fi
  fi

  if [ "$dirty" != 0 ]; then
    lines+=("$dirty fichier(s) modifié(s) non commité(s)")
  fi

  if gitf rev-parse -q --verify '@{u}' > /dev/null; then
    ahead="$(gitf rev-list --count '@{u}..HEAD')"
    behind="$(gitf rev-list --count 'HEAD..@{u}')"
    if [ "$ahead" != 0 ]; then lines+=("$ahead commit(s) pas encore sur GitHub : git push"); fi
    if [ "$behind" != 0 ]; then lines+=("GitHub a $behind commit(s) de plus : git pull"); fi
    if [ -e "$stateDir/unreachable" ]; then
      since="$(command cat "$stateDir/unreachable")"
      if [ $(($(date +%s) - since)) -gt 86400 ]; then
        lines+=("GitHub injoignable depuis plus d'un jour : écart avec GitHub non vérifié")
      fi
    fi
  fi

  if command -v secrets > /dev/null && [[ "$(secrets help 2>&1)" == *"secrets status"* ]]; then
    if ! out="$(secrets status 2> /dev/null)" || [ -n "$out" ]; then
      lines+=("secrets à synchroniser : secrets status")
    fi
  fi

  for f in kernel initrd kernel-modules; do
    if [ "$(readlink -f "$booted/$f")" != "$(readlink -f "$current/$f")" ]; then
      lines+=("noyau mis à jour : redémarrage nécessaire")
      break
    fi
  done
}

yellow="" green="" reset=""
if [ -t 1 ]; then yellow=$'\e[33m' green=$'\e[32m' reset=$'\e[0m'; fi

showLines() {
  echo "${yellow}⚠ $host diverge de sa configuration :${reset}"
  printf '  · %s\n' "${lines[@]}"
}

if [ -z "$flake" ] || [ ! -d "$flake/.git" ]; then
  case "${1:-}" in
    greet | fetch) exit 0 ;;
    -h | --help | help) usage; exit 0 ;;
    *) echo "dotstate : pas de dépôt de configuration dans $flake." >&2; exit 1 ;;
  esac
fi

case "${1:-}" in
  "")
    fetchUpstream
    compute
    if [ ${#lines[@]} -eq 0 ]; then
      echo "${green}✓ $host : système, dépôt et GitHub en phase.${reset}"
    else
      showLines
    fi
    ;;
  greet)
    compute
    if [ ${#lines[@]} -gt 0 ]; then showLines; fi
    systemctl --user start --no-block dotstate.service 2> /dev/null || true
    ;;
  fetch) fetchUpstream ;;
  -h | --help | help) usage ;;
  *)
    usage >&2
    exit 1
    ;;
esac
