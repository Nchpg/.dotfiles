# shellcheck shell=bash
# dotstate : l'état de cette machine face à sa configuration.
#
#   dotstate         met à jour depuis GitHub, puis affiche l'état complet
#   dotstate greet   à l'ouverture d'un shell : n'affiche rien si tout est en
#                    phase, sinon le détail (sans réseau, l'écart avec GitHub
#                    vient du dernier fetch)
#   dotstate fetch   met à jour depuis GitHub, sans rien afficher (timer)
#
# Comparés : ce qui TOURNE (le commit gravé dans le système, cf.
# modules/system/revision), le DÉPÔT local, et GITHUB (au dernier fetch). Plus
# les secrets (`secrets status`) et un redémarrage en attente.

# MY_FLAKE : posé par home.sessionVariables (modules/user/home-manager), et
# repassé explicitement au timer systemd (cf. default.nix). Absent, il n'y a
# rien à suivre : traité plus bas comme « pas de dépôt ici ».
flake="${MY_FLAKE:-}"
stateDir="${XDG_RUNTIME_DIR:-/tmp/dotstate-$(id -u)}/dotstate"
# Système actif et système démarré. Remplaçables pour les tests uniquement
# (DOTSTATE_CURRENT, DOTSTATE_BOOTED) : on ne peut pas fabriquer un faux
# /run/current-system.
current="${DOTSTATE_CURRENT:-/run/current-system}"
booted="${DOTSTATE_BOOTED:-/run/booted-system}"
host="${HOSTNAME:-$(uname -n)}"

# `secrets` est une commande du système (scripts/secrets.sh), et
# le timer tourne avec un PATH réduit.
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

# GITHUB, sans jamais rien demander : le timer tourne sans terminal, une
# invite de mot de passe (ou la fenêtre de l'agent) le bloquerait jusqu'à
# expiration. Trois voies, dans l'ordre, la première qui réussit gagne :
#   1. `git fetch origin` tel quel, en SSH par l'agent s'il est là ;
#   2. HTTPS avec les assistants d'identification de l'utilisateur (gh) ;
#   3. HTTPS anonyme, qui suffit pour un dépôt public.
# Seule la branche suivie est mise à jour. L'heure du PREMIER échec d'une
# série est notée (`unreachable`), effacée au premier succès : sans elle, un
# fetch qui échoue en silence laisserait croire que le dépôt est en phase avec
# GitHub. Compter depuis les échecs, et non depuis le dernier succès, évite de
# crier « injoignable » avant même le premier fetch.
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

# EMPREINTE DU CONTENU d'un commit : une ligne « <chemin> <sha256> » par
# fichier, triées, puis le sha256 de l'ensemble. EXACTEMENT le calcul de
# lib/flake/content-hash.nix, gravé au build dans /etc/dotfiles/content : toute
# modification de l'un doit se reporter dans l'autre. Mémorisée pour le
# dernier commit vu (`content`), le calcul ne se refait qu'à un commit neuf.
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

# Une ligne par écart, avec quoi faire. Rien si tout est en phase.
compute() {
  local head running run dirty n ahead behind out f since deploy="" sysContent

  head="$(gitf rev-parse -q --verify HEAD)" || return 0

  # Modifications non commitées des fichiers suivis : ce qu'un rebuild
  # prendrait sans qu'elles soient dans aucun commit.
  dirty="$(gitf status --porcelain --untracked-files=no | wc -l)"

  # 1. Ce qui tourne, face au dépôt local.
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
      # Construit avec des modifications non commitées, depuis abandonnées :
      # le système contient quelque chose qui n'est nulle part.
      deploy="système construit avec des modifications abandonnées depuis : rebuild"
    fi
    # Commits différents, mais peut-être le même CONTENU : construit avec des
    # modifications, puis ces mêmes modifications commitées. L'empreinte
    # gravée au build tranche ; sans elle (système plus ancien), on s'en tient
    # aux commits.
    if [ -n "$deploy" ]; then
      sysContent="$(command cat "$current/etc/dotfiles/content" 2> /dev/null || true)"
      if [ -n "$sysContent" ] && [ "$(contentOf "$head" || true)" = "$sysContent" ]; then
        deploy=""
      fi
    fi
    if [ -n "$deploy" ]; then lines+=("$deploy"); fi
  fi

  # 2. Modifications non commitées.
  if [ "$dirty" != 0 ]; then
    lines+=("$dirty fichier(s) modifié(s) non commité(s)")
  fi

  # 3. GitHub, au dernier fetch.
  if gitf rev-parse -q --verify '@{u}' > /dev/null; then
    ahead="$(gitf rev-list --count '@{u}..HEAD')"
    behind="$(gitf rev-list --count 'HEAD..@{u}')"
    if [ "$ahead" != 0 ]; then lines+=("$ahead commit(s) pas encore sur GitHub : git push"); fi
    if [ "$behind" != 0 ]; then lines+=("GitHub a $behind commit(s) de plus : git pull"); fi
    # Injoignable depuis plus d'un jour : les deux lignes ci-dessus datent du
    # dernier fetch réussi, et peuvent ne plus rien dire.
    if [ -e "$stateDir/unreachable" ]; then
      since="$(command cat "$stateDir/unreachable")"
      if [ $(($(date +%s) - since)) -gt 86400 ]; then
        lines+=("GitHub injoignable depuis plus d'un jour : écart avec GitHub non vérifié")
      fi
    fi
  fi

  # 4. Secrets : rien à dire tant que `secrets status` est muet et rend 0.
  if command -v secrets > /dev/null && [[ "$(secrets help 2>&1)" == *"secrets status"* ]]; then
    if ! out="$(secrets status 2> /dev/null)" || [ -n "$out" ]; then
      lines+=("secrets à synchroniser : secrets status")
    fi
  fi

  # 5. Un noyau, un initrd ou des modules plus récents que ceux du démarrage.
  for f in kernel initrd kernel-modules; do
    if [ "$(readlink -f "$booted/$f")" != "$(readlink -f "$current/$f")" ]; then
      lines+=("noyau mis à jour : redémarrage nécessaire")
      break
    fi
  done
}

# Couleurs seulement vers un terminal.
yellow="" green="" reset=""
if [ -t 1 ]; then yellow=$'\e[33m' green=$'\e[32m' reset=$'\e[0m'; fi

showLines() {
  echo "${yellow}⚠ $host diverge de sa configuration :${reset}"
  printf '  · %s\n' "${lines[@]}"
}

# Pas de dépôt ici (autre utilisateur, root, MY_FLAKE absent) : rien à
# suivre, en silence pour les usages automatiques.
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
    # Et un fetch en arrière-plan pour la prochaine fois : sur une machine où
    # l'on n'est pas toujours connecté, comme le serveur, le timer ne tourne
    # qu'avec la session.
    systemctl --user start --no-block dotstate.service 2> /dev/null || true
    ;;
  fetch) fetchUpstream ;;
  -h | --help | help) usage ;;
  *)
    usage >&2
    exit 1
    ;;
esac
