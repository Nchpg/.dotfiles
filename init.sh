#!/usr/bin/env bash
set -euo pipefail

flake="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/lib/ui.sh
. "$flake/scripts/lib/ui.sh"
# shellcheck source=scripts/lib/hooks.sh
. "$flake/scripts/lib/hooks.sh"
# shellcheck source=scripts/lib/sops-anchors.sh
. "$flake/scripts/lib/sops-anchors.sh"

skip() { echo "${WARN}·${R} $*"; }
# Échap/Ctrl-C : code non nul, d'où le `|| die` à l'appel.
input() { gum input --header "$1" --value "${2:-}" --placeholder "${3:-}"; }
choose() {
  local title="$1" sel="$2"
  shift 2
  gum choose --header "$title" --label-delimiter=$'\t' ${sel:+--selected "$sel"} "$@"
}
secret() { gum input --password --header "$1"; }
# RFC 1123 ; LC_ALL=C : sinon [a-z] accepte « é ».
validName() { local LC_ALL=C; [[ $1 =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; }
validHost() {
  validName "$1" && [[ $1 =~ ^[a-z] ]] \
    && [[ ! " if then else let in rec with inherit assert or " == *" $1 "* ]]
}

[ "$(id -u)" -ne 0 ] || die "à lancer en tant qu'utilisateur : le script appelle sudo lui-même."
command -v git > /dev/null || die "git absent : nix-shell -p git --run ./init.sh"

[ -f "$flake/flake.nix" ] || die "$flake ne ressemble pas au dépôt (pas de flake.nix)."

# Emplacement imposé : home-manager fige MY_FLAKE sur ~/.dotfiles.
[ "$flake" = "$HOME/.dotfiles" ] \
  || die "le dépôt doit être cloné dans ~/.dotfiles (ici : $flake) — mv \"$flake\" ~/.dotfiles"

secretsRepo="${MY_SECRETS:-$HOME/.secrets}"
secretsUrl="${MY_SECRETS_URL:-git@github.com:Nchpg/secrets.git}"

nixPkg() {
  nix --extra-experimental-features 'nix-command flakes' \
    build --no-link --print-out-paths --inputs-from "$flake" "nixpkgs-stable#$1" \
    2> >(grep -v '^warning: Git tree' >&2)
}
[ -t 0 ] && [ -t 1 ] || die "à lancer dans un terminal : le script pose des questions."

export GUM_CHOOSE_CURSOR="› "
if ! command -v gum > /dev/null; then
  gumPkg="$(nixPkg gum)" || die "impossible de récupérer gum depuis nixpkgs (réseau ?)."
  PATH="$gumPkg/bin:$PATH"
fi

# Le nom de HOST, pas `hostname` : il vaut `nixos` sur une install neuve, `<profil>-<host>` ensuite.
mapfile -t hosts < <(find "$flake/hosts" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
mapfile -t profiles < <(find "$flake/profiles" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
host="" profile="" detected=""
current="$(hostname)"
for p in "${profiles[@]}"; do
  h="${current#"$p"-}"
  if [ "$h" != "$current" ] && [ -d "$flake/hosts/$h" ]; then host="$h" profile="$p" detected="$h"; fi
done

gum style --bold --foreground 4 --border rounded --border-foreground 8 --padding "0 2" --margin "1 0" \
  "Préparation d'une machine" "dépôt : $flake"

newLabel="＋ nouvelle machine…"
opts=() selLabel="$newLabel"
for h in "${hosts[@]}"; do
  if [ "$h" = "$detected" ]; then
    selLabel="$h  (cette machine)"
    opts=("$selLabel"$'\t'"$h" "${opts[@]}")
  else
    opts+=("$h  (réinstallation)"$'\t'"$h")
  fi
done
opts+=("$newLabel"$'\t'"")
host="$(choose "Quelle machine est-ce ?" "$selLabel" "${opts[@]}")" || die "abandon."
if [ -z "$host" ]; then
  while :; do
    host="$(input "Nom de la nouvelle machine" "" "laptop, pc-salon…")" || die "abandon."
    if ! validHost "$host"; then
      skip "« $host » : minuscules, chiffres et tirets, en commençant par une lettre (pas un mot-clé Nix)."
    elif [ -d "$flake/hosts/$host" ]; then
      skip "« $host » existe déjà : pour la réinstaller, relance et choisis-la dans la liste."
    else
      break
    fi
  done
fi
if [ -n "$detected" ] && [ "$host" != "$detected" ]; then
  [ ! -d "$flake/hosts/$host" ] \
    || die "« $host » est une autre machine, celle-ci tourne la config de « $detected »."
  confirm "Cette machine tourne la config de « $detected ». La renommer en « $host » ?" no \
    || die "abandon."
fi

# Réinstallation ou faute de frappe : l'inscription remplacerait les clés de l'autre machine.
thisMachine() {
  local pub
  command -v age-keygen > /dev/null && [ -f "$HOME/.config/sops/age/keys.txt" ] \
    && [ -f "$secretsRepo/.sops.yaml" ] || return 1
  pub="$(age-keygen -y "$HOME/.config/sops/age/keys.txt" 2> /dev/null | grep '^age1pq1' | head -1 || true)"
  [ -n "$pub" ] && anchors "$secretsRepo/.sops.yaml" | grep -qxF "$host-user"$'\t'"$pub"
}
if [ -z "$detected" ] && [ -d "$flake/hosts/$host" ] \
  && git -C "$flake" cat-file -e "@{u}:hosts/$host" 2> /dev/null && ! thisMachine; then
  echo "« $host » existe déjà. Si c'est cette machine que tu réinstalles, ses clés"
  echo "seront REMPLACÉES par celles d'ici dans le dépôt de secrets."
  confirm "Réinstallation de « $host » ?" no \
    || die "abandon : choisis « nouvelle machine » pour un nouveau PC."
fi
entryOf() { awk -v h="$host" '$0 ~ "^[[:space:]]*" h " = \\[" {f=1} f {print} f && /\]/ {exit}'; }

if [ -z "$profile" ]; then
  profile="$(entryOf < "$flake/hosts/default.nix" | grep -oE '"[a-z0-9-]+"' | head -1 | tr -d '"' || true)"
fi
profile="${profile:-personal}"
opts=() selLabel=""
for p in "${profiles[@]}"; do
  opts+=("$p"$'\t'"$p")
  if [ "$p" = "$profile" ]; then selLabel="$p"; fi
done
profile="$(choose "Quel profil fait-elle tourner ?" "$selLabel" "${opts[@]}")" || die "abandon."

echo
gum style --bold --foreground 4 "$host ($profile)"
echo
sudo -v || die "sudo requis."

# `git add` : un flake ne voit que les fichiers suivis.
hwFile="$flake/hosts/$host/hardware-configuration.nix"
# Fichier temporaire : un échec du générateur n'écrase rien.
editTmp=""
cleanup() {
  rm -f "$editTmp"
  rmdir "$(dirname "$hwFile")" 2> /dev/null || true
}
trap cleanup EXIT
rewrite() {
  local file="$1"
  shift
  editTmp="$(mktemp "$file.XXXXXX")"
  "$@" > "$editTmp" || { rm -f "$editTmp"; editTmp=""; return 1; }
  if [ -e "$file" ]; then chmod --reference="$file" "$editTmp"; else chmod 644 "$editTmp"; fi
  mv "$editTmp" "$file"
  editTmp=""
}
writeHw() {
  mkdir -p "$(dirname "$hwFile")"
  rewrite "$hwFile" nixos-generate-config --show-hardware-config \
    || die "nixos-generate-config a échoué (cf. message ci-dessus)."
  git -C "$flake" add "$hwFile"
}
cfgFile="$flake/hosts/$host/configuration.nix"
if [ ! -f "$cfgFile" ]; then
  release="$(nixos-version | cut -d. -f1-2)"
  mkdir -p "$(dirname "$cfgFile")"
  cat > "$cfgFile" <<NIX
{ lib, ... }:

# Réglages propres à $host, importés par hosts/default.nix.
# hardware-configuration.nix est généré à part. Créé par ./init.sh.
{
  # Release de la première installation de CE host : ne suit PAS les
  # upgrades, valeur par machine comme hardware-configuration.nix.
  system.stateVersion = "$release";

  home-manager.sharedModules = [ { home.stateVersion = lib.mkDefault "$release"; } ];
}
NIX
  git -C "$flake" add "$cfgFile"
  ok "nouveau host : $cfgFile créé (stateVersion $release)"
fi

if [ ! -f "$hwFile" ]; then
  writeHw
  ok "nouveau host : $hwFile généré (et ajouté à git)"
else
  mapfile -t missing < <(grep -oE '/dev/disk/by-(uuid|label|partuuid|id)/[^"]+' "$hwFile" | sort -u \
    | while read -r dev; do [ -e "$dev" ] || echo "$dev"; done)
  if [ ${#missing[@]} -eq 0 ]; then
    skip "$hwFile : tous ses disques sont présents"
  else
    skip "$hwFile cite des disques absents de cette machine :"
    printf '     %s\n' "${missing[@]}"
    if confirm "Le régénérer (réinstallation) ?" no; then
      writeHw
      ok "$hwFile régénéré"
    else
      skip "$hwFile conservé — le rebuild pourrait produire une machine qui ne démarre pas"
    fi
  fi
fi

# Répertoire traversable : `/var/lib/nix` en 0700 casse la config nix des utilisateurs non root.
tokenFile=/var/lib/nix/access-tokens.conf
sudo install -d -m 755 /var/lib/nix
if sudo test -s "$tokenFile"; then
  skip "jeton déjà en place ($tokenFile)"
else
  echo "   Jeton GitHub à portée fine, Contents: read sur le dépôt de secrets."
  echo "   Il sera écrit dans $tokenFile (0600 root), où tu pourras le relire"
  echo "   plus tard avec : sudo cat $tokenFile"
  token="$(secret "Jeton GitHub (lecture seule sur le dépôt de secrets)")" || die "abandon."
  [ -n "$token" ] || die "jeton vide."
  # Par un tuyau : ni argv, ni environnement, ni historique.
  printf 'access-tokens = github.com=%s\n' "$token" \
    | sudo sh -c "umask 077; cat > '$tokenFile'"
  unset token
  ok "jeton écrit dans $tokenFile (0600 root)"
fi

# `-pq` : paire hybride ML-KEM-768 + X25519. `age` refuse de mélanger hybrides et classiques mais SOPS l'accepte : le fichier s'ouvre alors avec la seule clé faible.
ageKeygen="$(command -v age-keygen || true)"
if [ -z "$ageKeygen" ]; then
  agePkg="$(nixPkg age)" || die "impossible de récupérer age depuis nixpkgs."
  ageKeygen="$agePkg/bin/age-keygen"
fi

sysKey=/var/lib/sops-nix/key.txt
sudo install -d -m 755 /var/lib/sops-nix
if sudo test -f "$sysKey"; then
  skip "clé système déjà présente ($sysKey)"
else
  sudo sh -c "umask 077; '$ageKeygen' -pq -o '$sysKey' 2> /dev/null" \
    || die "génération de la clé système échouée."
  ok "clé système hybride (ML-KEM-768 + X25519) générée ($sysKey)"
fi
# Uniquement les hybrides : `age-keygen -y` liste aussi l'ancienne clé classique.
sysPub="$(sudo "$ageKeygen" -y "$sysKey" 2> /dev/null | grep '^age1pq1' || true)"
[ -n "$sysPub" ] || die "$sysKey n'a aucune identité hybride (age1pq1) : en ajouter une avec age-keygen -pq."

# Identité dédiée : `ssh-to-age` ne peut pas produire de clé post-quantique.
userKey="$HOME/.config/sops/age/keys.txt"
if [ -f "$userKey" ]; then
  skip "clé utilisateur déjà présente ($userKey)"
else
  mkdir -p "$(dirname "$userKey")"
  if (umask 077; "$ageKeygen" -pq -o "$userKey" 2> /dev/null); then
    ok "clé utilisateur hybride générée ($userKey)"
  else
    rm -f "$userKey"
    die "génération de la clé utilisateur échouée."
  fi
fi
userPub="$("$ageKeygen" -y "$userKey" 2> /dev/null | grep '^age1pq1' || true)"
[ -n "$userPub" ] || die "$userKey n'a aucune identité hybride (age1pq1) : en ajouter une avec age-keygen -pq."

# GitHub répond toujours en code 1 à `ssh -T` : sortie capturée, sinon échec sous pipefail.
githubOk() {
  local out
  out="$(ssh "$@" -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 || true)"
  [[ "$out" == *"successfully authenticated"* ]]
}
sshKey="$HOME/.ssh/id_ed25519"
github=0
if githubOk -o BatchMode=yes; then
  github=1
  skip "accès SSH à GitHub déjà en place"
elif [ -f "$sshKey" ] && { echo "   Test de l'accès SSH à GitHub (phrase de passe de la clé possible)…"; githubOk; }; then
  github=1
  ok "accès SSH à GitHub"
else
  if [ ! -f "$sshKey" ]; then
    install -d -m 700 "$HOME/.ssh"
    ssh-keygen -q -t ed25519 -C "$(id -un)@$host" -f "$sshKey" \
      || die "génération de la clé SSH échouée."
    ok "clé SSH générée ($sshKey)"
  fi
  echo "   Ajoute cette clé à ton compte GitHub : https://github.com/settings/ssh/new"
  echo
  if [ -f "$sshKey.pub" ]; then pub="$(cat "$sshKey.pub")"; else pub="$(ssh-keygen -y -f "$sshKey")"; fi
  echo "     $pub"
  echo
  while :; do
    choice="$(choose "Clé ajoutée sur GitHub ?" "Vérifier" $'Vérifier\tcheck' $'Passer (à refaire plus tard)\tskip')" \
      || die "abandon."
    [ "$choice" != skip ] || break
    if githubOk; then github=1; break; fi
    echo "   Toujours refusé par GitHub."
  done
  if [ "$github" = 1 ]; then ok "accès SSH à GitHub"; else skip "accès SSH à GitHub non configuré"; fi
fi

dotUrl="$(git -C "$flake" remote get-url origin 2> /dev/null || true)"
if [[ "$dotUrl" =~ ^https://github\.com/([^/]+)/([^/]+)/?$ ]] && [ "$github" = 1 ]; then
  git -C "$flake" remote set-url origin "git@github.com:${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}.git"
  ok "remote du dépôt de config passé en SSH"
fi

if [ -d "$secretsRepo/.git" ]; then
  skip "dépôt de secrets déjà cloné ($secretsRepo)"
elif git clone "$secretsUrl" "$secretsRepo"; then
  ok "dépôt de secrets cloné dans $secretsRepo"
else
  skip "clone échoué — sans lui, la commande \`secrets\` ne trouvera rien."
  echo "   À refaire : git clone $secretsUrl $secretsRepo"
fi

if hooks_on "$flake"; then
  skip "hooks git déjà actifs"
else
  hooks_enable "$flake"
  ok "hooks git actifs (core.hooksPath = .githooks)"
fi

# Identité git passée par `-c` : home-manager ne la pose qu'au premier rebuild.
sopsYaml="$secretsRepo/.sops.yaml"
deployFile="$flake/hosts/default.nix"
hwRel="hosts/$host/hardware-configuration.nix"
cfgRel="hosts/$host/configuration.nix"
enrollMsg="feat: enroll $host"
name="$(git -C "$flake" config user.name || git -C "$flake" log -1 --format=%an)"
email="$(git -C "$flake" config user.email || git -C "$flake" log -1 --format=%ae)"
g() { git -C "$1" -c user.name="$name" -c user.email="$email" "${@:2}"; }

hasAnchors() {
  local a
  a="$(anchors)"
  grep -qxF "$host-sys"$'\t'"$sysPub" <<< "$a" && grep -qxF "$host-user"$'\t'"$userPub" <<< "$a"
}

anchorsOk() { [ -f "$sopsYaml" ] && hasAnchors < "$sopsYaml"; }
anchorsPushed() { git -C "$secretsRepo" show '@{u}:.sops.yaml' 2> /dev/null | hasAnchors; }
deployOk() { [[ "$(entryOf < "$deployFile")" == *"\"$profile\""* ]]; }
deployPushed() { [[ "$(git -C "$flake" show '@{u}:hosts/default.nix' 2> /dev/null | entryOf)" == *"\"$profile\""* ]]; }
hwPushed() {
  git -C "$flake" cat-file -e "@{u}:$hwRel" 2> /dev/null \
    && [ -z "$(git -C "$flake" status --porcelain -- "hosts/$host")" ] \
    && ! git -C "$flake" log --format=%s '@{u}..' -- "hosts/$host" 2> /dev/null | grep -qxF "$enrollMsg"
}
enrolled() { anchorsPushed && deployPushed && hwPushed; }

foreignAhead() {
  git -C "$1" log --format=%s '@{u}..' 2> /dev/null \
    | grep -cvxF -e "$enrollMsg" -e "$enrollMsg keys" || true
}

foreignEdits() {
  git -C "$1" diff -U0 HEAD -- "$2" | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' \
    | grep -cvE "$3" || true
}

# `reset --keep` refuse s'il devait écraser des modifications locales ; les fichiers du host que le reset retirerait sont mis de côté et remis.
resync() {
  local repo="$1" redo="$2" keep tmpd f
  git -C "$repo" fetch -q origin 2> /dev/null || return 1
  [ "$(foreignAhead "$repo")" = 0 ] || return 1
  git -C "$repo" checkout -q -- "$redo" 2> /dev/null || true
  tmpd="$(mktemp -d)"
  for f in "${@:3}"; do
    if [ -f "$repo/$f" ]; then mkdir -p "$tmpd/$(dirname "$f")"; cp -p "$repo/$f" "$tmpd/$f"; fi
  done
  keep=0
  g "$repo" reset -q --keep '@{u}' || keep=$?
  for f in "${@:3}"; do
    if [ -f "$tmpd/$f" ]; then mkdir -p "$repo/$(dirname "$f")"; cp -p "$tmpd/$f" "$repo/$f"; fi
  done
  rm -rf "$tmpd"
  return "$keep"
}

writeAnchor() {
  local n="$1" k="$2" last
  last="$(grep -nE "$ANCHOR_RE" "$sopsYaml" | tail -1 | cut -d: -f1 || true)"
  [ -n "$last" ] || die "aucune ancre dans $sopsYaml : impossible de situer la liste keys:."
  # shellcheck disable=SC2016 # programme awk, pas du shell
  rewrite "$sopsYaml" awk -v n="$n" -v k="$k" -v last="$last" '
    $0 ~ "^[[:space:]]*- &" n "[[:space:]]" { match($0, /^[[:space:]]*/); print substr($0, 1, RLENGTH) "- &" n " " k; done = 1; next }
    NR == last { match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH) }
    { print }
    NR == last && !done { print ind "- &" n " " k; done = 1 }
  ' "$sopsYaml"
}

addDeployment() {
  # shellcheck disable=SC2016 # programme awk, pas du shell
  rewrite "$deployFile" awk -v h="$host" -v p="$profile" '
    $0 ~ "^[[:space:]]*systemSettings\\.sops\\.deployments = \\{" { inblock = 1 }
    inblock && $0 ~ "^[[:space:]]*" h " = \\[" {
      found = 1
      if ($0 ~ /\];/) { sub(/[[:space:]]*\];/, " \"" p "\" ];"); print; next }
      inentry = 1; print; next
    }
    inentry && /^[[:space:]]*\];/ {
      match($0, /^[[:space:]]*/); print substr($0, 1, RLENGTH) "  \"" p "\""; inentry = 0
    }
    inblock && /^[[:space:]]*};/ {
      if (!found) { match($0, /^[[:space:]]*/); print substr($0, 1, RLENGTH) "  " h " = [ \"" p "\" ];" }
      inblock = 0
    }
    { print }
  ' "$deployFile"
}

if enrolled; then
  skip "$host déjà inscrite (ancres, deployments, matériel sur GitHub)"
elif [ "$github" != 1 ] || [ ! -f "$sopsYaml" ]; then
  skip "inscription impossible sans accès SSH à GitHub ni clone du dépôt de secrets — relance ./init.sh"
else
  echo
  echo "   Inscription de $host ($profile) :"
  if ! anchorsPushed; then
    if anchors "$sopsYaml" | cut -f1 | grep -qxE "$host-(sys|user)" && ! anchorsOk; then
      echo "     - ses deux clés publiques REMPLACENT les anciennes ($host-sys, $host-user) dans $sopsYaml"
    else
      echo "     - ses deux clés publiques dans $sopsYaml (ancres $host-sys, $host-user)"
    fi
  fi
  deployPushed || echo "     - \"$profile\" dans deployments.$host (hosts/default.nix)"
  hwPushed || echo "     - ses fichiers hosts/$host (matériel, configuration.nix)"
  anchorsPushed || echo "     - commit et push du dépôt de secrets"
  { deployPushed && hwPushed; } || echo "     - commit et push de la config"
  if ! confirm "Continuer ?" yes; then
    skip "inscription reportée — relance ./init.sh"
  else
    # Dépôt de secrets d'abord : sinon deployments citerait des ancres absentes.
    [ "$(foreignEdits "$secretsRepo" .sops.yaml "&$host-(sys|user)[[:space:]]")" = 0 ] \
      || die "$sopsYaml a des modifications non commitées : commite-les ou mets-les de côté, puis relance."
    if ! anchorsPushed; then
      n="$(foreignAhead "$secretsRepo")"
      if [ "$n" != 0 ]; then
        skip "$secretsRepo a $n autre(s) commit(s) non poussé(s) : pousse-les toi-même, puis relance ./init.sh"
      else
        for _ in 1 2 3; do
          resync "$secretsRepo" .sops.yaml || break
          writeAnchor "$host-sys" "$sysPub"
          writeAnchor "$host-user" "$userPub"
          if ! git -C "$secretsRepo" diff --quiet HEAD -- .sops.yaml; then
            g "$secretsRepo" commit -q -m "$enrollMsg keys" -- .sops.yaml
          fi
          if g "$secretsRepo" push -q 2> /dev/null; then break; fi
        done
        if anchorsPushed; then ok "ancres de $host poussées"; else skip "push du dépôt de secrets échoué — relance ./init.sh"; fi
      fi
    fi

    if ! anchorsPushed; then
      skip "config non poussée tant que les ancres ne le sont pas"
    elif ! deployPushed || ! hwPushed; then
      [ "$(foreignEdits "$flake" hosts/default.nix "$host = \\[|^\\+[[:space:]]*\"$profile\"\$")" = 0 ] \
        || die "hosts/default.nix a des modifications non commitées : commite-les ou mets-les de côté, puis relance."
      n="$(foreignAhead "$flake")"
      if [ "$n" != 0 ]; then
        skip "$flake a $n autre(s) commit(s) non poussé(s) : pousse-les toi-même, puis relance ./init.sh"
      else
        for _ in 1 2 3; do
          resync "$flake" hosts/default.nix "$hwRel" "$cfgRel" || break
          if ! deployOk; then
            addDeployment
            deployOk || die "bloc systemSettings.sops.deployments introuvable dans hosts/default.nix : ajoute-y $host = [ \"$profile\" ]; à la main, puis relance."
          fi
          git -C "$flake" add -- "hosts/$host" hosts/default.nix
          if ! git -C "$flake" diff --cached --quiet -- "hosts/$host" hosts/default.nix; then
            g "$flake" commit -q -m "$enrollMsg" -- "hosts/$host" hosts/default.nix
          fi
          git -C "$flake" add -- "hosts/$host" hosts/default.nix
          if g "$flake" push -q 2> /dev/null; then break; fi
        done
        if deployPushed && hwPushed; then
          ok "deployments et fichiers de $host poussés"
        else
          skip "push de la config échoué — relance ./init.sh"
        fi
      fi
    fi
  fi
fi

if [ "$github" = 1 ] && [ -d "$secretsRepo/.git" ] \
  && [ -z "$(git -C "$secretsRepo" status --porcelain --untracked-files=no)" ]; then
  git -C "$secretsRepo" pull -q --ff-only 2> /dev/null || true
fi
# Copie de `marker` (lib/sops/policy.nix) : ce script tourne sans évaluer le flake.
sopsMarker="# ATTENTION : bloc GÉNÉRÉ"

pendingSeal() {
  local re kind f rel key
  awk -v h="$host" -v marker="$sopsMarker" '
    index($0, marker) == 1 { gen = 1 }
    gen && /^[[:space:]]*- path_regex:/ { re = $3; next }
    gen && re != "" && $0 ~ "[*]" h "-sys([[:space:]]|$)" { print re "\tsys" }
    gen && re != "" && $0 ~ "[*]" h "-user([[:space:]]|$)" { print re "\tuser" }
  ' "$sopsYaml" | while IFS=$'\t' read -r re kind; do
    while IFS= read -r f; do
      rel="${f#"$secretsRepo"/}"
      [[ "$rel" =~ $re ]] || continue
      if [ "$kind" = sys ]; then key="$sysPub"; else key="$userPub"; fi
      grep -qF "recipient: $key" "$f" || echo "$rel"
    done < <(find "$secretsRepo" -mindepth 1 -name '*.yaml' ! -name '.*' -not -path '*/.git/*')
  done | sort -u
}

citedRules() {
  sed -n "/^$sopsMarker/,\$p" "$sopsYaml" | grep -cE "[*]$host-(sys|user)([[:space:]]|\$)" || true
}

echo
if enrolled; then
  mapfile -t unsealed < <(pendingSeal)
  if [ "$(citedRules)" != 0 ] && [ ${#unsealed[@]} -eq 0 ]; then
    ok "$host est destinataire de tous ses secrets."
    echo "   Si ce n'est pas déjà fait, premier rebuild : ./scripts/rebuild.sh --host $host --profile $profile"
  else
    echo "── reste une étape, sur une machine DÉJÀ autorisée ──"
    echo
    echo "     git pull && secrets policy"
    echo
    echo "   Elle montre quels fichiers $host va pouvoir ouvrir, demande confirmation,"
    echo "   les rescelle, pousse, puis te donne le commit du lock à faire (flake.lock)."
    if [ "$(citedRules)" != 0 ]; then
      echo "   Encore ${#unsealed[@]} fichier(s) à resceller pour $host."
    fi
    echo "   Les fichiers qu'elle ne peut pas ouvrir se font de même depuis une machine"
    echo "   qui le peut (think pour les secrets du serveur). Ensuite seulement, ici :"
    echo
    echo "     git pull && ./scripts/rebuild.sh --host $host --profile $profile"
  fi
else
  echo "── $host n'est pas encore inscrite (cf. ci-dessus) : relance ./init.sh ──"
  echo "   clé système      : $sysPub"
  echo "   clé utilisateur  : $userPub"
fi
