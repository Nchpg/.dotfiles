#!/usr/bin/env bash
set -euo pipefail

here="$(dirname "$0")"
# shellcheck source=scripts/lib/env.sh
. "$here/lib/env.sh"
# shellcheck source=scripts/lib/sops-anchors.sh
. "$here/lib/sops-anchors.sh"

# Figés au build, jamais résolus depuis l'environnement : sudo les exécute en root.
if [ -z "${DOTS_EDITOR:-}" ] || [ -z "${DOTS_NIX:-}" ]; then
  echo "secrets : à lancer par la commande \`secrets\` du système, pas depuis le clone." >&2
  exit 1
fi

sysAnchor="$DOTS_HOST-sys"

nixBin="$DOTS_NIX"

editorBin="$DOTS_EDITOR"

marker="$DOTS_SOPS_MARKER"

# Chemin résolu : un lien symbolique ou un `/` final fausserait `find`.
store="$(realpath -m "${MY_SECRETS:-$HOME/.secrets}")"
sopsConfig="$store/.sops.yaml"
keyFile=/var/lib/sops-nix/key.txt
assumeYes=""

secretPath() { printf '%s/%s.yaml' "$store" "$1"; }

rel() { printf '%s' "${1#"$store"/}"; }

# `! -name '.*'` écarte `.sops.yaml`, qui n'est pas un secret.
secretFiles() {
  find "$store" -mindepth 1 -name '*.yaml' ! -name '.*' -not -path '*/.git/*' | sort
}

usage() {
  cat >&2 <<'USAGE'
usage: secrets <commande>

  secrets edit <clé>     édite un secret, le CRÉE s'il n'existe pas
                         (politique régénérée d'abord), puis
                         synchronise
                         ex. secrets edit wireguard/gram_preshared_key
  secrets show <clé>     affiche une valeur
  secrets list           liste les secrets (aucun déchiffrement)
  secrets policy         régénère les règles du .sops.yaml depuis les
                         configurations, rescelle tout fichier dont les
                         destinataires diffèrent (après confirmation ;
                         --yes sans terminal), puis synchronise
  secrets sync           commit et push du dépôt privé, puis mise à
                         jour du lock, sans passer par l'éditeur
  secrets status         état du dépôt privé face au lock (muet si
                         tout est synchro ; code 1 si `sync` a du
                         travail, 2 s'il faut d'abord tirer)

Les secrets vivent dans un dépôt PRIVÉ ($MY_SECRETS, ~/.secrets par
défaut). Les secrets système ne sont déchiffrables que par root, et c'est
voulu : du code lancé sous ton compte ne doit pas pouvoir les lire.

Et pas par toutes les machines : chaque fichier n'est scellé que pour
celles qui en ont l'usage. Une machine ne peut donc pas éditer un secret
qui ne la concerne pas — c'est le comportement recherché, pas une panne.

Les hooks git du dépôt de config (.githooks) appellent `secrets git-hook`
pour garder les deux dépôts en phase : pull dans la config = pull ici,
push de la config = push d'ici d'abord.
USAGE
}

sopsBin="$(command -v sops)"

# HOME/XDG sur root : l'éditeur ne charge rien venu de ton compte.
asRoot() {
  sudo env \
    SOPS_AGE_KEY_FILE="$keyFile" \
    EDITOR="$editorBin" \
    HOME=/root \
    XDG_CONFIG_HOME=/root/.config \
    XDG_DATA_HOME=/root/.local/share \
    XDG_STATE_HOME=/root/.local/state \
    XDG_CACHE_HOME=/root/.cache \
    "$sopsBin" "$@"
}

# Tranché sur les destinataires, pas par essai-erreur : quitter sans enregistrer relancerait un éditeur root.
userPub=""
forUser() {
  if [ -z "$userPub" ]; then
    userPub="$(age-keygen -y "$HOME/.config/sops/age/keys.txt" 2> /dev/null | grep '^age1pq1' | sed 's/^/recipient: /' || true)"
    [ -n "$userPub" ] || userPub=none
  fi
  [ "$userPub" != none ] && grep -qF "$userPub" "$1"
}

forRoot() {
  local pub
  pub="$(anchors "$sopsConfig" 2> /dev/null | awk -F '\t' -v a="$sysAnchor" '$1 == a { k = $2 } END { print k }')"
  [ -n "$pub" ] && grep -q "recipient: $pub" "$1"
}

# Lignes « type<TAB>fichier<TAB>changements » ; type : here, elsewhere ou norule.
misSealed() {
  local kind f ch files
  [ -f "$sopsConfig" ] || return 0
  mapfile -t files < <(secretFiles)
  [ ${#files[@]} -gt 0 ] || return 0
  awk -v store="$store/" -v marker="$marker" '
    function nm(k) { return (k in rev) ? rev[k] : (k ~ /^\?/ ? substr(k, 2) "(ancre introuvable)" : substr(k, 1, 16) "…(inconnue)") }
    FILENAME == ARGV[1] { split($0, a, "\t"); key[a[1]] = a[2]; rev[a[2]] = a[1]; next }
    FILENAME == ARGV[2] {
      sub(/\r$/, "")
      if (index($0, marker) == 1) gen = 1
      if (gen && $0 ~ /^  - path_regex:/) { re[++r] = $3; next }
      if (gen && r && match($0, /\*[A-Za-z0-9_-]+/)) alias[r, ++na[r]] = substr($0, RSTART + 1, RLENGTH - 1)
      next
    }
    match($0, /recipient: age1[a-z0-9]+/) {
      k = substr($0, RSTART + 11, RLENGTH - 11)
      if (!((FILENAME, k) in act)) { act[FILENAME, k] = 1; nact[FILENAME]++; actl[FILENAME] = actl[FILENAME] " " k }
    }
    END {
      # Liste prise des ARGUMENTS : un fichier vide est sans ligne.
      for (i = 3; i < ARGC; i++) {
        f = ARGV[i]; rel = substr(f, length(store) + 1); m = 0
        for (j = 1; j <= r; j++) if (rel ~ re[j]) { m = j; break }
        if (!m) { print "norule\t" f; continue }
        split("", want); nwant = 0; bad = 0
        for (x = 1; x <= na[m]; x++) {
          k = (alias[m, x] in key) ? key[alias[m, x]] : "?" alias[m, x]
          if (!(k in want)) { want[k] = 1; nwant++; if (!((f, k) in act)) bad = 1 }
        }
        if (bad || nwant != nact[f] + 0) {
          ch = ""
          for (k in want) if (!((f, k) in act)) ch = ch " +" nm(k)
          na2 = split(actl[f], al, " ")
          for (x = 1; x <= na2; x++) if (!(al[x] in want)) ch = ch " -" nm(al[x])
          print "bad\t" f "\t" substr(ch, 2)
        }
      }
    }
  ' <(anchors "$sopsConfig") "$sopsConfig" "${files[@]}" | while IFS=$'\t' read -r kind f ch; do
    if [ "$kind" = norule ]; then
      printf 'norule\t%s\t\n' "$f"
    elif forUser "$f" || forRoot "$f"; then
      printf 'here\t%s\t%s\n' "$f" "$ch"
    else
      printf 'elsewhere\t%s\t%s\n' "$f" "$ch"
    fi
  done
}

# Le `chown` tourne en root sur un chemin modifiable par ton compte : `-h` et refus des liens évitent un lien vers /etc/shadow.
keepOwner() {
  local file="$1"
  shift
  local before after rc=0
  if [ -L "$file" ]; then
    echo "secrets : $file est un lien symbolique — refus." >&2
    return 1
  fi
  before="$(stat -c '%u:%g' "$file")"
  # Code rendu après la restauration (sinon `if err=$(…)` annoncerait « rescellé »).
  "$@" || rc=$?
  after="$(stat -c '%u:%g' "$file")"
  if [ "$before" != "$after" ]; then
    sudo chown -h "$before" -- "$file"
    echo "secrets : propriétaire de $file restauré ($before)" >&2
  fi
  return "$rc"
}

requireFile() {
  if [ ! -f "$1" ]; then
    echo "secrets : $1 introuvable — clone le dépôt privé ou définis MY_SECRETS." >&2
    exit 1
  fi
}

# `--ff-only` : en cas de divergence on s'arrête plutôt que de fusionner.
pullFirst() {
  hasOrigin || return 0

  if ! git -C "$store" rev-parse -q --verify '@{u}' > /dev/null; then
    if upRef > /dev/null; then
      echo "secrets : $store ne suit pas origin, mise à jour ignorée (git -C $store branch -u origin/$(git -C "$store" branch --show-current))." >&2
    else
      echo "secrets : $store ne suit aucune branche distante, mise à jour ignorée." >&2
    fi
    return 0
  fi

  if [ -n "$(git -C "$store" status --porcelain --untracked-files=no)" ]; then
    echo "secrets : modifications non commitées dans $store, mise à jour ignorée." >&2
    return 0
  fi

  if ! git -C "$store" pull --ff-only -q; then
    echo "secrets : impossible de mettre $store à jour (historiques divergents ?)." >&2
    echo "  À régler à la main : git -C $store status" >&2
    return 1
  fi
}

sopsPath() {
  local out="" part
  local IFS=/
  for part in $1; do
    out="${out}[\"$part\"]"
  done
  printf '%s' "$out"
}

# Nix renomme l'entrée en `secrets_2` en cas de doublon : on suit le nœud de la racine.
lockedRev() {
  jq -r '.nodes[.nodes.root.inputs.secrets // ""].locked.rev // empty'
}

aheadCount() {
  local up
  up="$(upRef)" || { echo 0; return 0; }
  git -C "$store" rev-list --count "$up..HEAD" 2> /dev/null || echo 0
}

upRef() {
  local b
  git -C "$store" rev-parse -q --verify '@{u}' 2> /dev/null && return 0
  b="$(git -C "$store" branch --show-current)"
  [ -n "$b" ] && git -C "$store" rev-parse -q --verify "origin/$b" 2> /dev/null
}

hasOrigin() { git -C "$store" remote get-url origin > /dev/null 2>&1; }

behindCount() { git -C "$store" rev-list --count "HEAD..$1"; }

stalePullHint() {
  echo "  D'abord : git -C $store pull --ff-only (modifications mises de côté si besoin)" >&2
}

# Sans le lock, les machines déploient l'ancienne valeur.
sync() {
  local did="" head locked up stray n

  if [ ! -f "$flake/flake.lock" ]; then
    echo "secrets : $flake/flake.lock introuvable, lock non mis à jour." >&2
    return 1
  fi

  locked="$(lockedRev < "$flake/flake.lock")"
  if [ -n "$locked" ] && ! git -C "$store" merge-base --is-ancestor "$locked" HEAD 2> /dev/null; then
    echo "secrets : $store est en retard sur le lock (${locked:0:7})." >&2
    stalePullHint
    return 1
  fi
  if ! git -C "$store" symbolic-ref -q HEAD > /dev/null; then
    echo "secrets : HEAD détaché dans $store, rien synchronisé (git -C $store status)." >&2
    return 1
  fi
  if hasOrigin; then
    git -C "$store" fetch -q origin 2> /dev/null || true
    if up="$(upRef)" && [ "$(behindCount "$up")" != 0 ]; then
      echo "secrets : $store est en retard sur origin." >&2
      stalePullHint
      return 1
    fi
  fi

  # Jamais `git add -A`.
  git -C "$store" add -u
  while IFS= read -r n; do
    if grep -q '^sops:' "$store/$n" 2> /dev/null; then git -C "$store" add -- "$n"; fi
  done < <(git -C "$store" ls-files -o --exclude-standard -- '*.yaml')
  stray="$(git -C "$store" ls-files -o --exclude-standard)"
  if [ -n "$stray" ]; then
    echo "secrets : fichiers non suivis laissés de côté (pas des secrets chiffrés) :" >&2
    printf '%s\n' "$stray" | sed 's/^/  /' >&2
  fi
  if ! git -C "$store" diff --cached --quiet; then
    git -C "$store" commit -q -m "${1:-chore: update secrets}"
    echo "secrets : commit dans $store"
    did=1
  fi

  if ! hasOrigin; then
    echo "secrets : aucun remote sur $store, pousse-le à la main." >&2
  elif ! git -C "$store" rev-parse -q --verify '@{u}' > /dev/null; then
    git -C "$store" push -q -u origin HEAD
    echo "secrets : poussé (branche suivie créée)"
    did=1
  elif [ "$(aheadCount)" != 0 ]; then
    git -C "$store" push -q
    echo "secrets : poussé"
    did=1
  fi

  head="$(git -C "$store" rev-parse HEAD)"
  if [ "$locked" = "$head" ]; then
    [ -n "$did" ] || echo "secrets : rien à synchroniser."
    return 0
  fi

  # `--refresh` : nix tient l'entrée pour fraîche une heure (`tarball-ttl`).
  # Sous sudo : le jeton est en 0600 root, sinon 404 sur le dépôt privé.
  keepOwner "$flake/flake.lock" \
    sudo env \
      NIX_CONFIG='!include /var/lib/nix/access-tokens.conf' \
      GIT_CONFIG_COUNT=1 \
      GIT_CONFIG_KEY_0=safe.directory \
      GIT_CONFIG_VALUE_0="$flake" \
      "$nixBin" flake update secrets --refresh --flake "$flake" || true
  locked="$(lockedRev < "$flake/flake.lock")"
  if [ "$locked" != "$head" ]; then
    echo >&2
    echo "secrets : ATTENTION, le lock ne pointe PAS sur ton dernier commit." >&2
    echo "  dépôt : $head" >&2
    echo "  lock  : $locked" >&2
    echo "  Un rebuild déploierait l'ancienne valeur. Relance : secrets sync" >&2
    return 1
  fi

  echo
  echo "── lock à jour sur $head ──"
  git -C "$flake" --no-pager diff --stat flake.lock
  echo "   git -C $flake commit -m 'chore: bump secrets' -- flake.lock && git -C $flake push"
  n="$(git -C "$flake" status --porcelain --untracked-files=no | grep -vc ' flake.lock$' || true)"
  if [ "$n" != 0 ]; then
    echo "   ($n autre(s) fichier(s) modifié(s) dans la config : si l'un déclare ce secret,"
    echo "    commite-le avec le lock, sinon le check sops-policy de la CI échouera)"
  fi
}

# `--yes` obligatoire : l'invite de `updatekeys` lirait le flux de la boucle et l'échec passerait pour un succès.
rescell() {
  local f err skipped=() failed=0 run

  for f in "$@"; do
    if forUser "$f"; then
      run=("$sopsBin")
    else
      run=(asRoot)
    fi

    if err="$(keepOwner "$f" "${run[@]}" --config "$sopsConfig" updatekeys --yes "$f" 2>&1)"; then
      echo "secrets : $(rel "$f") rescellé"
    elif [[ "$err" == *"no matching creation rules"* ]]; then
      echo "secrets : $(rel "$f") — AUCUNE règle dans .sops.yaml, regénère la politique (secrets policy)" >&2
      failed=1
    elif [[ "$err" == *"Failed to get the data key"* ]]; then
      skipped+=("$(rel "$f")")
    else
      echo "secrets : $(rel "$f") — échec :" >&2
      printf '%s\n' "$err" | sed 's/^/    /' >&2
      failed=1
    fi
  done

  if [ ${#skipped[@]} -gt 0 ]; then
    echo >&2
    echo "secrets : non déchiffrables sur cette machine, à resceller depuis celle qui les détient :" >&2
    printf '  %s\n' "${skipped[@]}" >&2
  fi
  return "$failed"
}

# Code : 0 bon, 1 rescellement échoué, 2 génération impossible, 3 refusé à la confirmation.
applyPolicy() {
  local quiet="${1:-}" generated new old kind f ch reply
  local -a here=() hereCh=() elsewhere=() norule=()
  requireFile "$sopsConfig"
  if ! grep -qF "$marker" "$sopsConfig"; then
    echo "secrets : marqueur « $marker » absent de $sopsConfig." >&2
    return 2
  fi

  # Une sortie sans le marqueur effacerait toutes les règles : refusée.
  local nixErr
  nixErr="$(mktemp)"
  if ! generated="$("$nixBin" run "$flake#sops-policy" 2> "$nixErr")" \
    || ! grep -qF "$marker" <<< "$generated"; then
    echo "secrets : calcul de la politique impossible ($nixBin run $flake#sops-policy) :" >&2
    grep -v '^warning: Git tree' "$nixErr" | tail -15 | sed 's/^/    /' >&2
    rm -f "$nixErr"
    return 2
  fi
  rm -f "$nixErr"

  local up
  if up="$(upRef)" && [ "$(behindCount "$up")" != 0 ]; then
    echo "secrets : $store est en retard sur origin : git -C $store pull --ff-only d'abord." >&2
    return 2
  fi

  local defined cited missing unused
  defined="$(anchors "$sopsConfig" | cut -f1 | sort -u)"
  cited="$(grep -oE '\*[A-Za-z0-9_-]+' <<< "$generated" | tr -d '*' | sort -u)"
  missing="$(comm -13 <(printf '%s\n' "$defined") <(printf '%s\n' "$cited") | tr '\n' ' ')"
  if [ -n "${missing// /}" ]; then
    echo "secrets : la politique cite des ancres absentes du .sops.yaml : $missing" >&2
    echo "  Machine dans deployments pas encore inscrite ? (./init.sh sur elle, puis git -C $store pull)" >&2
    return 2
  fi
  unused="$(comm -23 <(sed -E 's/-(sys|user)$//' <<< "$defined" | sort -u) \
    <(sed -E 's/-(sys|user)$//' <<< "$cited" | sort -u) | tr '\n' ' ')"
  if [ -n "${unused// /}" ]; then
    echo "secrets : machine(s) inscrite(s) sans aucun secret ici : $unused— absente(s) de deployments ? (git -C $flake pull)" >&2
  fi

  new="$(sed "/^$marker/,\$d" "$sopsConfig")"$'\n'"$generated"
  old="$(cat "$sopsConfig")"
  if [ "$new" != "$old" ]; then
    printf '%s\n' "$new" > "$sopsConfig"
    echo "secrets : règles du .sops.yaml régénérées depuis les configurations."
  fi

  while IFS=$'\t' read -r kind f ch; do
    case "$kind" in
      here) here+=("$f") hereCh+=("$(printf '%-44s %s' "$(rel "$f")" "$ch")") ;;
      elsewhere) elsewhere+=("$(printf '%-44s %s' "$(rel "$f")" "$ch")") ;;
      norule) norule+=("$(rel "$f")") ;;
    esac
  done < <(misSealed)

  if [ ${#norule[@]} -gt 0 ]; then
    echo "secrets : sans règle dans le .sops.yaml (secret plus déclaré nulle part ?) :" >&2
    printf '  %s\n' "${norule[@]}" >&2
  fi
  if [ ${#elsewhere[@]} -gt 0 ]; then
    echo "secrets : à resceller depuis une machine qui peut les ouvrir (secrets policy là-bas) :" >&2
    printf '  %s\n' "${elsewhere[@]}" >&2
  fi
  if [ ${#here[@]} -eq 0 ]; then
    [ -n "$quiet" ] || echo "secrets : fichiers ouvrables ici tous scellés selon la politique."
    return 0
  fi

  echo "secrets : accès à modifier (+ donné, - retiré) :"
  printf '  %s\n' "${hereCh[@]}"
  if [ -z "$assumeYes" ]; then
    if [ -t 0 ]; then
      read -rp "Appliquer ? [Y/n] " reply || reply=n
    else
      echo "secrets : pas de terminal pour confirmer (secrets policy --yes pour forcer)." >&2
      reply=n
    fi
    if [[ "$reply" =~ ^[nN]$ ]]; then
      if [ "$new" != "$old" ]; then printf '%s\n' "$old" > "$sopsConfig"; fi
      echo "secrets : rien rescellé, .sops.yaml laissé tel qu'il était." >&2
      return 3
    fi
  fi
  rescell "${here[@]}"
}

cmd_edit() {
  if [ $# -lt 2 ]; then usage; exit 2; fi
  pullFirst || exit 1
  file="$(secretPath "$2")"

  policyRc=0
  applyPolicy quiet || policyRc=$?
  if [ "$policyRc" -ge 2 ] && [ ! -f "$file" ]; then exit 1; fi

  # Règle du secret, ou celle de son site (`<site>/<clé>`, cf. lib/sops/policy.nix).
  site="${2%%/*}"
  if [ ! -f "$file" ] && ! grep -qF "path_regex: ^${2//./\\.}\\.ya?ml\$" "$sopsConfig" \
    && ! { [ "$site/${2#*/}" = "$2" ] && [ "${2#*/}" = "${2##*/}" ] \
      && grep -qF "path_regex: ^${site//./\\.}/[^/]+\\.ya?ml\$" "$sopsConfig"; }; then
    echo "secrets : aucune règle pour « $2 » : ce secret n'est déclaré dans aucun module." >&2
    echo "  Déclare d'abord sops.secrets.\"$2\" dans le module qui l'utilise (git add si" >&2
    echo "  le fichier est nouveau : un flake ne voit que les fichiers suivis), puis relance." >&2
    echo "  Pour un site d'apps.json : « <site>/<clé> » (ex. myetf/env) se crée directement." >&2
    if [ -n "$(git -C "$store" status --porcelain)" ]; then
      sync "chore: regenerate sops policy" || true
    fi
    exit 1
  fi

  if [ ! -f "$file" ]; then
    # `--config` explicite, seulement ici : pour un secret existant, une config risquerait de réécrire l'audience.
    echo "secrets : $2 n'existe pas, création." >&2
    echo "  Structure attendue dans l'éditeur :" >&2
    ind="    "
    IFS=/ read -ra parts <<< "$2"
    for i in "${!parts[@]}"; do
      if [ "$i" -eq $((${#parts[@]} - 1)) ]; then
        echo "$ind${parts[$i]}: <valeur>" >&2
      else
        echo "$ind${parts[$i]}:" >&2
      fi
      ind="$ind    "
    done
    echo >&2
    mkdir -p "$(dirname "$file")"
    EDITOR="$editorBin" "$sopsBin" --config "$sopsConfig" "$file"
    sync "chore: add secret $2"
    exit 0
  fi

  editRc=0
  if forUser "$file"; then
    EDITOR="$editorBin" "$sopsBin" "$file" || editRc=$?
  else
    keepOwner "$file" asRoot "$file" || editRc=$?
  fi
  if [ "$editRc" != 0 ]; then
    if [ -n "$(git -C "$store" status --porcelain --untracked-files=no)" ]; then
      sync "chore: regenerate sops policy" || true
    elif [ "$editRc" = 200 ]; then
      echo "secrets : $2 inchangé."
    fi
    if [ "$editRc" = 200 ]; then exit 0; fi
    exit "$editRc"
  fi
  sync "chore: update secret $2"
}

cmd_show() {
  if [ $# -lt 2 ]; then usage; exit 2; fi
  file="$(secretPath "$2")"
  requireFile "$file"
  if forUser "$file"; then
    "$sopsBin" --decrypt --extract "$(sopsPath "$2")" "$file"
  else
    asRoot --decrypt --extract "$(sopsPath "$2")" "$file"
  fi
}

cmd_list() {
  secretFiles | sed "s|^$store/||;s|\.yaml$||"
}

cmd_policy() {
  if [ "${2:-}" = --yes ]; then assumeYes=1; fi
  pullFirst || exit 1
  rc=0
  applyPolicy || rc=$?
  if [ "$rc" = 2 ] || [ "$rc" = 3 ]; then exit 1; fi
  sync "chore: regenerate sops policy"
  exit "$rc"
}

cmd_sync() {
  sync "${2:-chore: update secrets}"
}

cmd_status() {
  # Code de sortie lu par rebuild.sh : 0 rien à faire (ou seulement en retard), 1 `sync` peut agir, 2 il faut tirer d'abord.
  [ -d "$store/.git" ] || exit 0
  out=()
  rc=0
  stale=0 diverged=0

  dirty="$(git -C "$store" status --porcelain)"
  if [ -n "$dirty" ]; then
    out+=("modifications non commitées :")
    while IFS= read -r l; do out+=("  $l"); done <<< "$dirty"
    rc=1
  fi

  if ! up="$(upRef)"; then
    out+=("aucune branche distante (origin/<branche>) : sync en créera une")
  else
    ahead="$(aheadCount)"
    behind="$(behindCount "$up")"
    if [ "$ahead" != 0 ]; then
      out+=("$ahead commit(s) non poussé(s)")
      rc=1
    fi
    if [ "$behind" != 0 ]; then
      out+=("$behind commit(s) sur origin pas encore tirés")
      stale=1
      if [ "$ahead" != 0 ]; then diverged=1; fi
    fi
  fi

  head="$(git -C "$store" rev-parse HEAD)"
  locked="$({ lockedRev < "$flake/flake.lock"; } 2> /dev/null || true)"
  if [ -n "$locked" ] && [ "$locked" != "$head" ]; then
    if git -C "$store" merge-base --is-ancestor "$locked" HEAD 2> /dev/null; then
      n="$(git -C "$store" rev-list --count "$locked..HEAD")"
      out+=("$n commit(s) pas encore dans le lock : un rebuild déploierait l'ancienne valeur")
      rc=1
    elif git -C "$store" merge-base --is-ancestor HEAD "$locked" 2> /dev/null; then
      out+=("en retard sur le lock (${locked:0:7})")
      stale=1
    elif git -C "$store" cat-file -e "$locked^{commit}" 2> /dev/null; then
      out+=("HEAD et lock (${locked:0:7}) ont divergé")
      stale=1 diverged=1
    else
      out+=("le lock pointe sur ${locked:0:7}, absent d'ici")
      stale=1
    fi
  fi

  nHere=0 nElsewhere=0 nNorule=0
  while IFS=$'\t' read -r kind _ _; do
    case "$kind" in
      here) nHere=$((nHere + 1)) ;;
      elsewhere) nElsewhere=$((nElsewhere + 1)) ;;
      norule) nNorule=$((nNorule + 1)) ;;
    esac
  done < <(misSealed)
  if [ "$nHere" != 0 ]; then
    out+=("$nHere fichier(s) scellé(s) autrement que le .sops.yaml : secrets policy")
  fi
  if [ "$nElsewhere" != 0 ]; then
    out+=("$nElsewhere fichier(s) à resceller depuis une machine qui peut les ouvrir")
  fi
  if [ "$nNorule" != 0 ]; then
    out+=("$nNorule fichier(s) sans règle dans le .sops.yaml (secrets policy pour le détail)")
  fi

  if [ ${#out[@]} -gt 0 ]; then
    echo "── secrets ($store) ──"
    printf '  %s\n' "${out[@]}"
    if [ "$diverged" = 1 ]; then
      echo "  → à régler à la main (un pull --ff-only n'y suffira pas) : git -C $store status"
    elif [ "$stale" = 1 ] && [ "$rc" = 1 ]; then
      echo "  → git -C $store pull --ff-only, puis secrets sync"
    elif [ "$stale" = 1 ]; then
      echo "  → git -C $store pull --ff-only"
    elif [ "$rc" = 1 ]; then
      echo "  → secrets sync"
    fi
  fi
  if [ "$rc" = 1 ] && [ "$stale" = 1 ]; then exit 2; fi
  exit "$rc"
}

cmd_git_hook() {
  repo="$(git rev-parse --show-toplevel 2> /dev/null || printf '%s' "$flake")"

  # git exporte GIT_DIR et consorts : `git -C "$store"` viserait le dépôt de config.
  mapfile -t gitVars < <(git rev-parse --local-env-vars)
  unset "${gitVars[@]}"
  [ -d "$store/.git" ] || exit 0

  has() { git -C "$store" merge-base --is-ancestor "$1" HEAD 2> /dev/null; }

  case "${2:-}" in
    post-merge | post-rewrite)
      if [ "$2" = post-rewrite ] && [ "${3:-}" != rebase ]; then exit 0; fi
      locked="$({ lockedRev < "$repo/flake.lock"; } 2> /dev/null || true)"
      if [ -z "$locked" ] || has "$locked"; then exit 0; fi

      echo "secrets : le lock a avancé, mise à jour de $store…"
      pullFirst || true
      if ! has "$locked"; then
        echo "secrets : $store ne contient toujours pas la révision du lock (${locked:0:7}) — secrets status" >&2
      fi
      exit 0
      ;;

    pre-push)
      # Le serveur construit avec le lock POUSSÉ : un commit de secrets resté ici ferait échouer son rebuild.
      revs=()
      while read -r _ sha _ _; do
        if [[ "$sha" =~ ^0+$ ]]; then continue; fi
        rev="$(git -C "$repo" show "$sha:flake.lock" 2> /dev/null | lockedRev || true)"
        if [ -n "$rev" ]; then revs+=("$rev"); fi
      done
      onOrigin() { [ -n "$(git -C "$store" branch -r --list 'origin/*' --contains "$1" 2> /dev/null)" ]; }

      pending=()
      for rev in "${revs[@]}"; do
        if ! onOrigin "$rev"; then pending+=("$rev"); fi
      done
      [ ${#pending[@]} -gt 0 ] || exit 0

      if ! git -C "$store" fetch -q --prune origin; then
        echo "secrets : fetch de $store impossible, push annulé (git push --no-verify pour passer outre)." >&2
        exit 1
      fi

      for rev in "${pending[@]}"; do
        if onOrigin "$rev"; then continue; fi
        if has "$rev"; then
          echo "secrets : le lock poussé pointe sur ${rev:0:7}, pas encore sur origin — push de $store d'abord."
          git -C "$store" push -q || true
        fi
        if ! onOrigin "$rev"; then
          echo "secrets : le lock poussé pointe sur ${rev:0:7}, introuvable sur l'origin de $store." >&2
          echo "  Le serveur ne pourrait pas le récupérer. secrets status pour le détail," >&2
          echo "  git push --no-verify pour passer outre." >&2
          exit 1
        fi
      done
      ;;

    *)
      echo "secrets : hook inconnu « ${2:-} »" >&2
      exit 1
      ;;
  esac
}
case "${1:-help}" in
  edit) cmd_edit "$@" ;;
  show) cmd_show "$@" ;;
  list) cmd_list "$@" ;;
  policy) cmd_policy "$@" ;;
  sync) cmd_sync "$@" ;;
  status) cmd_status "$@" ;;
  git-hook) cmd_git_hook "$@" ;;
  -h | --help | help)
    usage
    ;;
  *)
    echo "secrets : commande inconnue « $1 »" >&2
    usage
    exit 1
    ;;
esac

