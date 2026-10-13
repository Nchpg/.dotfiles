#!/usr/bin/env bash
# Prépare une machine neuve : tout ce qu'il faut poser AVANT le premier
# rebuild, dans le bon ordre et surtout avec les bons droits. Seul prérequis :
#
#   nix-shell -p git
#   git clone https://github.com/Nchpg/.dotfiles.git ~/.dotfiles && ~/.dotfiles/init.sh
#
# Étapes : 1. host et profil — 2. matériel — 3. jeton de lecture — 4. clé
# système — 5. clé utilisateur — 6. accès SSH à GitHub — 7. clone du dépôt de
# secrets — 8. hooks git — 9. inscription (ancres, deployments, matériel).
#
# Pourquoi un script plutôt qu'une section de doc : ce sont les MODES de fichiers
# qui se trompent quand un humain suit une procédure. `/var/lib/nix` en 0700 au
# lieu de 0755 paraît plus prudent et casse silencieusement toute la
# configuration nix des utilisateurs non root — nix n'ignore pas un include
# qu'il ne peut pas atteindre, il jette /etc/nix/nix.conf en entier. Constaté.
#
# Chaque étape est IDEMPOTENTE : relancer le script saute ce qui est déjà en
# place, et ne réécrit rien sans le demander. Il ne touche jamais à un secret.
#
# Ce qu'il NE PEUT PAS faire : s'autoriser lui-même. Il inscrit la machine
# (ses clés, son profil), mais ne peut pas resceller des fichiers qu'il n'ouvre
# pas : c'est `secrets policy` sur une machine DÉJÀ autorisée, et le script
# finit en le disant.
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
skip() { echo -e "${YELLOW}·${NC} $*"; }
die()  { echo -e "${RED}✗${NC} $*" >&2; exit 1; }
# LES QUESTIONS, par gum. Échap ou Ctrl-C y rendent un code non nul, que
# l'appelant transforme en abandon : `… || die "abandon."` À L'APPEL, et pas
# dans ces fonctions, qui tournent souvent dans un `$(…)` dont un `exit` ne
# quitterait que le sous-shell.
#   input   <titre> [valeur] [exemple]          -> texte saisi
#   choose  <titre> <libellé présélectionné> <libellé<TAB>valeur>…  -> valeur
#   confirm <question> yes|no                   -> 0 oui, 1 non (abandon sur Échap)
#   secret  <titre>                             -> texte saisi, masqué
input() { gum input --header "$1" --value "${2:-}" --placeholder "${3:-}"; }
choose() {
  local title="$1" sel="$2"
  shift 2
  gum choose --header "$title" --label-delimiter=$'\t' ${sel:+--selected "$sel"} "$@"
}
confirm() {
  local rc=0
  gum confirm "$1" --default="$([ "$2" = yes ] && echo true || echo false)" || rc=$?
  [ "$rc" -le 1 ] || die "abandon."
  return "$rc"
}
secret() { gum input --password --header "$1"; }
# Nom de host ou de profil (RFC 1123, comme l'assertion de
# modules/system/network). LC_ALL=C : sous une locale UTF-8, [a-z] accepte « é ».
validName() { local LC_ALL=C; [[ $1 =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; }
# Un host devient aussi une clé d'attribut Nix (`<host> = [ … ];` dans
# deployments) : il doit commencer par une lettre et ne pas être un mot-clé,
# sinon hosts/default.nix ne s'évalue plus (`2pc`, `in`, `rec`…).
validHost() {
  validName "$1" && [[ $1 =~ ^[a-z] ]] \
    && [[ ! " if then else let in rec with inherit assert or " == *" $1 "* ]]
}

[ "$(id -u)" -ne 0 ] || die "à lancer en tant qu'utilisateur : le script appelle sudo lui-même."
# Absent d'une installation NixOS neuve, et requis par presque chaque étape.
command -v git > /dev/null || die "git absent : nix-shell -p git --run ./init.sh"

flake="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$flake/flake.nix" ] || die "$flake ne ressemble pas au dépôt (pas de flake.nix)."

# EMPLACEMENT IMPOSÉ : home-manager fige MY_FLAKE sur ~/.dotfiles
# (modules/user/home-manager), et `rebuild`, `secrets`, `update`… le cherchent
# là. Un clone ailleurs passerait ce script et le premier rebuild, puis toutes
# les commandes échoueraient en « flake introuvable ».
[ "$flake" = "$HOME/.dotfiles" ] \
  || die "le dépôt doit être cloné dans ~/.dotfiles (ici : $flake) — mv \"$flake\" ~/.dotfiles"

secretsRepo="${MY_SECRETS:-$HOME/.secrets}"
secretsUrl="${MY_SECRETS_URL:-git@github.com:Nchpg/secrets.git}"

# gum pour les questions, pris dans le nixpkgs ÉPINGLÉ par le flake (la même
# version que `update` et `dots`) : absent d'une machine neuve, il se
# télécharge en une seconde. Pas de repli sans lui : sans réseau, ce script ne
# mènerait à rien de toute façon (clone des secrets, clé SSH, push).
#
# Même procédé pour tout outil absent d'une machine neuve (cf. age, plus bas).
nixPkg() {
  nix --extra-experimental-features 'nix-command flakes' \
    build --no-link --print-out-paths --inputs-from "$flake" "nixpkgs-stable#$1" \
    2> >(grep -v '^warning: Git tree' >&2)
}
[ -t 0 ] && [ -t 1 ] || die "à lancer dans un terminal : le script pose des questions."

# COULEURS : les rôles de `update` (accent, succès, texte, atténué), mais en
# numéros de couleur du TERMINAL plutôt qu'en codes hexadécimaux. Ce script
# tourne avant le premier rebuild, sans accès à la palette Stylix ; or Stylix
# colore justement le terminal avec elle (4 = base0D, 2 = base0B, 7 = base05,
# 8 = base03). Résultat : les couleurs du thème sur une machine configurée,
# celles du terminal par défaut sur une machine neuve, jamais le rose de gum.
export GUM_CHOOSE_CURSOR_FOREGROUND=4 GUM_CHOOSE_HEADER_FOREGROUND=4 \
  GUM_CHOOSE_SELECTED_FOREGROUND=2 GUM_CHOOSE_ITEM_FOREGROUND=7 GUM_CHOOSE_CURSOR="› " \
  GUM_INPUT_HEADER_FOREGROUND=4 GUM_INPUT_PROMPT_FOREGROUND=4 GUM_INPUT_CURSOR_FOREGROUND=4 \
  GUM_INPUT_PLACEHOLDER_FOREGROUND=8 \
  GUM_CONFIRM_PROMPT_FOREGROUND=4 GUM_CONFIRM_SELECTED_BACKGROUND=4 \
  GUM_CONFIRM_SELECTED_FOREGROUND=0 GUM_CONFIRM_UNSELECTED_BACKGROUND=8 \
  GUM_CONFIRM_UNSELECTED_FOREGROUND=7
if ! command -v gum > /dev/null; then
  gumPkg="$(nixPkg gum)" || die "impossible de récupérer gum depuis nixpkgs (réseau ?)."
  PATH="$gumPkg/bin:$PATH"
fi

# ── 1. Quelle machine, quel profil ──────────────────────────────────────────
#
# Le nom de HOST, pas `hostname` : c'est lui qui nomme le dossier hosts/<host>,
# les ancres `<host>-sys`/`<host>-user` du .sops.yaml et l'entrée de
# `deployments`. Le hostname vaut `nixos` sur une installation neuve, et
# `<profil>-<host>` une fois la config appliquée (modules/system/network) : ni
# l'un ni l'autre n'est le bon nom. On le déduit de ce second cas quand c'est
# possible (relance du script), sinon on le demande.
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

# La machine : celle que ce système fait déjà tourner en tête, puis les
# autres hosts (pour une réinstallation), puis un nom nouveau.
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
# Machine déjà configurée sous un autre nom. Vers un host EXISTANT, c'est
# toujours une erreur : ce dossier décrit une autre machine, et continuer
# proposerait d'écraser son fichier matériel avec les disques d'ici (que son
# prochain rebuild, ou l'auto-upgrade nocturne du serveur, prendrait pour de
# bon), puis d'inscrire les clés d'ici dans ses ancres. Réinstaller cette
# autre machine se fait sur elle, où rien n'est détecté. Vers un NOUVEAU nom,
# c'est un renommage : permis, après confirmation.
if [ -n "$detected" ] && [ "$host" != "$detected" ]; then
  [ ! -d "$flake/hosts/$host" ] \
    || die "« $host » est une autre machine, celle-ci tourne la config de « $detected »."
  confirm "Cette machine tourne la config de « $detected ». La renommer en « $host » ?" no \
    || die "abandon."
fi

# Machine neuve (rien de détecté) sous le nom d'un host EXISTANT : c'est soit
# la réinstallation de cette machine, soit une faute de frappe. Dans le second
# cas, l'inscription remplacerait les clés de l'autre machine dans le dépôt de
# secrets, et le `secrets policy` suivant lui retirerait l'accès à ses propres
# secrets. On le fait dire explicitement.
#
# Pas de question si le dossier n'existe qu'ici (reste d'un lancement
# interrompu, jamais poussé), ni si les ancres de ce host portent déjà la clé
# utilisateur de cette machine (relance avant le premier rebuild, quand le
# hostname vaut encore `nixos`) : ce n'est alors pas une autre machine.
thisMachine() {
  local pub
  command -v age-keygen > /dev/null && [ -f "$HOME/.config/sops/age/keys.txt" ] \
    && [ -f "$secretsRepo/.sops.yaml" ] || return 1
  pub="$(age-keygen -y "$HOME/.config/sops/age/keys.txt" 2> /dev/null | grep '^age1pq1' | head -1 || true)"
  [ -n "$pub" ] && grep -qE "&$host-user[[:space:]]+$pub([[:space:]]|\$)" "$secretsRepo/.sops.yaml"
}
if [ -z "$detected" ] && [ -d "$flake/hosts/$host" ] \
  && git -C "$flake" cat-file -e "@{u}:hosts/$host" 2> /dev/null && ! thisMachine; then
  echo "« $host » existe déjà. Si c'est cette machine que tu réinstalles, ses clés"
  echo "seront REMPLACÉES par celles d'ici dans le dépôt de secrets."
  confirm "Réinstallation de « $host » ?" no \
    || die "abandon : choisis « nouvelle machine » pour un nouveau PC."
fi
# Profil proposé : celui que la machine tourne (déduit du hostname), sinon,
# pour un host déjà inscrit (réinstallation), le premier de son entrée dans
# deployments, sinon personal.
if [ -z "$profile" ]; then
  profile="$(awk -v h="$host" '$0 ~ "^[[:space:]]*" h " = \\[" {f=1} f {print} f && /\]/ {exit}' "$flake/hosts/default.nix" \
    | grep -oE '"[a-z0-9-]+"' | head -1 | tr -d '"' || true)"
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

# ── 2. Matériel : hosts/<host>/hardware-configuration.nix ──────────────────
#
# Absent pour un nouveau host : on le génère. PÉRIMÉ après une réinstallation :
# les UUID des partitions changent, et un rebuild avec l'ancien fichier produit
# une machine qui ne démarre plus.
#
# Le critère est donc « les disques qu'il cite existent-ils ici ? », pas une
# comparaison de texte : le fichier versionné est reformaté, et la sortie de
# nixos-generate-config évolue d'une version à l'autre — il « différerait »
# toujours.
#
# `git add` : un flake ne voit que les fichiers suivis, un fichier neuf serait
# ignoré au rebuild (cf. le piège flake dans docs/secrets.md).
hwFile="$flake/hosts/$host/hardware-configuration.nix"
# Par un fichier temporaire : un échec du générateur ne laisse pas un fichier
# vidé à la place de l'ancien.
# Le trap retire les fichiers temporaires (et le dossier du host s'il est resté
# vide) aussi sur Ctrl-C, sinon ils traînaient en « ?? » à côté des vrais.
hwTmp="" editTmp=""
cleanup() {
  rm -f "$hwTmp" "$editTmp"
  rmdir "$(dirname "$hwFile")" 2> /dev/null || true
}
trap cleanup EXIT
writeHw() {
  mkdir -p "$(dirname "$hwFile")"
  hwTmp="$(mktemp "$hwFile.XXXXXX")"
  nixos-generate-config --show-hardware-config > "$hwTmp" \
    || die "nixos-generate-config a échoué (cf. message ci-dessus)."
  chmod 644 "$hwTmp"
  mv "$hwTmp" "$hwFile"
  hwTmp=""
  git -C "$flake" add "$hwFile"
}
# Et hosts/<host>/configuration.nix, pour un nouveau host : la stateVersion,
# release de la PREMIÈRE installation, qui ne doit pas suivre les montées de
# nixpkgs (sans elle, NixOS prend celle du nixpkgs courant et la fait bouger).
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
    echo -e "${YELLOW}·${NC} $hwFile cite des disques absents de cette machine :"
    printf '     %s\n' "${missing[@]}"
    # Non par défaut : un disque externe débranché tombe aussi dans ce cas, et
    # régénérer le ferait disparaître du fichier. L'ancien reste dans git.
    if confirm "Le régénérer (réinstallation) ?" no; then
      writeHw
      ok "$hwFile régénéré"
    else
      skip "$hwFile conservé — le rebuild pourrait produire une machine qui ne démarre pas"
    fi
  fi
fi

# ── 3. Jeton de lecture du dépôt de secrets ─────────────────────────────────
#
# Identifiant d'AMORÇAGE : il donne accès aux secrets, il ne peut donc pas venir
# des secrets. Le fichier est en 0600 root, mais son répertoire DOIT rester
# traversable, cf. l'en-tête.
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
  # Par un tuyau : ni argv, ni environnement, ni historique de shell.
  printf 'access-tokens = github.com=%s\n' "$token" \
    | sudo sh -c "umask 077; cat > '$tokenFile'"
  unset token
  ok "jeton écrit dans $tokenFile (0600 root)"
fi

# ── 4. Clé système, pour les secrets lus par root ───────────────────────────
#
# `-pq` : paire HYBRIDE ML-KEM-768 + X25519. Le secret partagé dérive des deux
# mécanismes, donc casser X25519 laisse ML-KEM et réciproquement — la sécurité
# est au moins égale à celle d'une clé classique, jamais inférieure.
#
# Ce n'est pas décoratif : sops emballe sa clé de données pour chaque
# destinataire, et une clé classique est du X25519 pur. Un adversaire qui archive
# le dépôt de secrets aujourd'hui pourrait le lire le jour où les machines
# quantiques arrivent, ce qui viderait de son sens la clé pré-partagée WireGuard.
#
# Et il n'y a pas de demi-mesure : `age` refuse de mélanger destinataires
# hybrides et classiques, mais SOPS accepte le mélange sans un mot, et le fichier
# s'ouvre alors avec la seule clé faible. Une machine qui arriverait avec une clé
# classique casserait donc la propriété pour tout le monde.
#
# Chemin ABSOLU du binaire : il est lancé par sudo, dont le PATH n'est pas le
# tien, et sur une machine neuve `age` ne vient d'aucun profil. On le matérialise
# donc dans le store avant de s'en servir.
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
# Uniquement les destinataires HYBRIDES. `age-keygen -y` liste TOUTES les
# identités du fichier, et les machines migrées gardent leur ancienne clé
# classique à côté de la nouvelle : afficher les deux ferait enrôler la mauvaise,
# ce qui casserait la propriété post-quantique sans un message.
sysPub="$(sudo "$ageKeygen" -y "$sysKey" 2> /dev/null | grep '^age1pq1' || true)"
# Clé ancienne restaurée, ou fichier abîmé : sans identité hybride, il n'y a
# rien à enrôler, et la suite parlerait de « deux clés » en n'en montrant qu'une.
[ -n "$sysPub" ] || die "$sysKey n'a aucune identité hybride (age1pq1) : en ajouter une avec age-keygen -pq."

# ── 5. Clé utilisateur, pour tes propres secrets ────────────────────────────
# Identité DÉDIÉE, et non plus dérivée de la clé SSH. Une clé ed25519 ne donne
# que du X25519, donc pas d'hybride : `ssh-to-age` ne peut pas produire de clé
# post-quantique, et une clé de signature ML-DSA ne se convertit pas en clé de
# chiffrement. La dérivation était commode — restaurer sa clé SSH suffisait à
# tout retrouver — mais elle est incompatible avec l'objectif.
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

# ── 6. Accès SSH à GitHub ───────────────────────────────────────────────────
#
# Le dépôt de config se clone en HTTPS, il est public. Le dépôt de secrets, lui,
# est privé et se clone en SSH, et c'est par SSH que les deux se poussent (le
# hook pre-push pousse les secrets avant la config). Sur un PC neuf aucune clé
# n'est enregistrée chez GitHub : on en crée une, on attend qu'elle soit
# ajoutée, et on vérifie.
#
# Pas le jeton de l'étape 3 : il est en lecture seule, et il vit en 0600 root
# précisément pour ne pas être à portée de ton compte.
#
# `accept-new` : la clé d'hôte de GitHub est enregistrée au premier contact.
# Confiance au premier usage, comme un `git clone` interactif l'aurait demandé.
#
# Premier essai en BatchMode (muet), les suivants sans : une clé protégée par
# une phrase de passe, sans agent, échoue en BatchMode alors qu'elle est bien
# enregistrée chez GitHub.
#
# Sortie capturée et non passée dans un tube : GitHub répond TOUJOURS en code 1
# à `ssh -T`, authentifié ou non, et sous `pipefail` le tube échouerait même
# quand le message de réussite est là.
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
  # Depuis la clé privée si le .pub manque (clé restaurée seule).
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

# Le clone HTTPS ne sait pas pousser : on bascule sur SSH, même dépôt.
dotUrl="$(git -C "$flake" remote get-url origin 2> /dev/null || true)"
if [[ "$dotUrl" =~ ^https://github\.com/([^/]+)/([^/]+)/?$ ]] && [ "$github" = 1 ]; then
  git -C "$flake" remote set-url origin "git@github.com:${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}.git"
  ok "remote du dépôt de config passé en SSH"
fi

# ── 7. Dépôt privé des secrets ──────────────────────────────────────────────
if [ -d "$secretsRepo/.git" ]; then
  skip "dépôt de secrets déjà cloné ($secretsRepo)"
elif git clone "$secretsUrl" "$secretsRepo"; then
  ok "dépôt de secrets cloné dans $secretsRepo"
else
  echo -e "${YELLOW}·${NC} clone échoué — sans lui, la commande \`secrets\` ne trouvera rien."
  echo "   À refaire : git clone $secretsUrl $secretsRepo"
fi

# ── 8. Hooks git du dépôt de config ─────────────────────────────────────────
#
# Formatage au commit, et surtout les deux dépôts tenus en phase : pull de la
# config = pull des secrets, push de la config = push des secrets d'abord (cf.
# `secrets git-hook`). Réglage local au clone, d'où sa place ici : sans lui, un
# push depuis cette machine pourrait publier un lock que le serveur ne sait pas
# récupérer.
if [ "$(git -C "$flake" config --get core.hooksPath || true)" = .githooks ]; then
  skip "hooks git déjà actifs"
else
  git -C "$flake" config core.hooksPath .githooks
  ok "hooks git actifs (core.hooksPath = .githooks)"
fi

# ── 9. Inscription : ancres, deployments, matériel ─────────────────────────
#
# Tout ce qu'une machine neuve peut écrire d'elle-même, et qu'il fallait avant
# recopier à la main depuis une machine autorisée (dont deux clés de près de
# deux mille caractères) :
#   - ses deux ANCRES dans le .sops.yaml du dépôt de secrets, remplacées si
#     elles existent (réinstallation sans restaurer les clés) ;
#   - son PROFIL dans `deployments` (hosts/default.nix), seule information
#     qui dise qu'elle fait tourner ce profil pour de vrai ;
#   - son fichier MATÉRIEL : la machine autorisée calcule la politique en
#     évaluant `<profil>-<host>`, ce qui exige hosts/<host>.
#
# SANS DANGER : une clé publique ajoutée ne donne accès à rien. Les fichiers ne
# s'ouvrent pour cette machine qu'une fois RESCELLÉS par une machine qui les
# ouvre déjà — `secrets policy` là-bas, qui affiche avant d'agir quelle machine
# gagne l'accès à quels fichiers, et demande confirmation. C'est là, et
# seulement là, que l'accès se donne.
#
# Identité git : celle de git si elle existe, sinon celle du dernier commit du
# dépôt (le tien) — home-manager ne la pose qu'au premier rebuild. Par `-c` sur
# CHAQUE commande : le rebase du pull réécrit le commit, et échouait faute
# d'identité en laissant le dépôt en plein rebase.
sopsYaml="$secretsRepo/.sops.yaml"
deployFile="$flake/hosts/default.nix"
hwRel="hosts/$host/hardware-configuration.nix"
cfgRel="hosts/$host/configuration.nix"
enrollMsg="feat: enroll $host"
name="$(git -C "$flake" config user.name || git -C "$flake" log -1 --format=%an)"
email="$(git -C "$flake" config user.email || git -C "$flake" log -1 --format=%ae)"
g() { git -C "$1" -c user.name="$name" -c user.email="$email" "${@:2}"; }

# L'entrée de deployments, de `<host> = [` jusqu'au `]` (nixfmt l'éclate sur
# plusieurs lignes dès deux profils), lue sur l'entrée standard.
entryOf() { awk -v h="$host" '$0 ~ "^[[:space:]]*" h " = \\[" {f=1} f {print} f && /\]/ {exit}'; }
hasAnchors() {
  grep -qE "&$host-sys[[:space:]]+$sysPub([[:space:]]|\$)" \
    && grep -qE "&$host-user[[:space:]]+$userPub([[:space:]]|\$)" "$sopsYaml"
}

# CE QUI COMPTE, C'EST CE QUI EST SUR GITHUB : la machine autorisée ne voit
# que ça. Ici (local) et là-bas (branche suivie), pour chaque élément.
anchorsOk() { [ -f "$sopsYaml" ] && hasAnchors < "$sopsYaml"; }
anchorsPushed() { git -C "$secretsRepo" show '@{u}:.sops.yaml' 2> /dev/null | hasAnchors; }
deployOk() { [[ "$(entryOf < "$deployFile")" == *"\"$profile\""* ]]; }
deployPushed() { [[ "$(git -C "$flake" show '@{u}:hosts/default.nix' 2> /dev/null | entryOf)" == *"\"$profile\""* ]]; }
# Les fichiers du host (matériel, configuration.nix) : sur GitHub, sans
# régénération non commitée ici, ni commit d'INSCRIPTION non poussé qui les
# touche. Tes propres commits sur hosts/<host> ne comptent pas : sur une
# machine déjà en service, c'est du travail ordinaire, pas une inscription.
hwPushed() {
  git -C "$flake" cat-file -e "@{u}:$hwRel" 2> /dev/null \
    && [ -z "$(git -C "$flake" status --porcelain -- "hosts/$host")" ] \
    && ! git -C "$flake" log --format=%s '@{u}..' -- "hosts/$host" 2> /dev/null | grep -qxF "$enrollMsg"
}
enrolled() { anchorsPushed && deployPushed && hwPushed; }

# COMMITS LOCAUX D'AUTRE CHOSE que l'inscription : ce script ne pousse JAMAIS
# un dépôt qui en contient. Le push embarquerait ton travail en cours — et le
# serveur se reconstruit chaque nuit depuis GitHub.
foreignAhead() {
  git -C "$1" log --format=%s '@{u}..' 2> /dev/null \
    | grep -cvxF -e "$enrollMsg" -e "$enrollMsg keys" || true
}

# MODIFICATIONS NON COMMITÉES qui ne viennent pas de ce script : on refuse de
# toucher au fichier plutôt que de les commiter sous « enroll ». Ne sont
# tolérées que les lignes qu'une inscription interrompue aurait laissées
# (`$3`, une regex).
foreignEdits() {
  git -C "$1" diff -U0 HEAD -- "$2" | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' \
    | grep -cvE "$3" || true
}

# RECALAGE SUR GITHUB avant d'écrire, et nouvel essai si un push est refusé
# parce que GitHub a avancé (deux machines qui s'inscrivent en même temps).
# Plutôt qu'un rebase, qui entrait en conflit sur les mêmes lignes à chaque
# relance : on revient à la branche distante et on REFAIT l'inscription, qui
# est mécanique (deux ancres, une ligne de deployments).
#
# `reset --keep` : met à jour l'arbre pour ce qui a bougé là-bas, garde les
# modifications locales des autres fichiers, et refuse s'il devait en écraser
# une. N'est appelé que si les seuls commits locaux sont ceux de l'inscription
# (foreignAhead), et après avoir écarté nos propres retouches non commitées
# du fichier à refaire ($2). Les fichiers du host, que le reset retirerait de
# l'arbre puisqu'ils ne sont pas encore là-bas, sont mis de côté et remis.
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

# Ancre `&<nom> <clé>` : remplacée si elle existe, sinon ajoutée après la
# dernière ancre de la liste, à la même indentation. Droits du fichier gardés.
writeAnchor() {
  local n="$1" k="$2" last
  last="$(grep -nE '^[[:space:]]*- &[A-Za-z0-9_-]+[[:space:]]+age1' "$sopsYaml" | tail -1 | cut -d: -f1 || true)"
  [ -n "$last" ] || die "aucune ancre dans $sopsYaml : impossible de situer la liste keys:."
  editTmp="$(mktemp "$sopsYaml.XXXXXX")"
  awk -v n="$n" -v k="$k" -v last="$last" '
    $0 ~ "^[[:space:]]*- &" n "[[:space:]]" { match($0, /^[[:space:]]*/); print substr($0, 1, RLENGTH) "- &" n " " k; done = 1; next }
    NR == last { match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH) }
    { print }
    NR == last && !done { print ind "- &" n " " k; done = 1 }
  ' "$sopsYaml" > "$editTmp"
  chmod --reference="$sopsYaml" "$editTmp"
  mv "$editTmp" "$sopsYaml"
  editTmp=""
}

# Profil ajouté à deployments : à la liste du host si elle existe (une ligne
# ou plusieurs), sinon une entrée neuve avant l'accolade fermante du bloc.
# nixfmt repasse derrière (hook pre-commit).
addDeployment() {
  editTmp="$(mktemp "$deployFile.XXXXXX")"
  awk -v h="$host" -v p="$profile" '
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
  ' "$deployFile" > "$editTmp"
  chmod --reference="$deployFile" "$editTmp"
  mv "$editTmp" "$deployFile"
  editTmp=""
}

if enrolled; then
  skip "$host déjà inscrite (ancres, deployments, matériel sur GitHub)"
elif [ "$github" != 1 ] || [ ! -f "$sopsYaml" ]; then
  skip "inscription impossible sans accès SSH à GitHub ni clone du dépôt de secrets — relance ./init.sh"
else
  echo
  echo "   Inscription de $host ($profile) :"
  if ! anchorsPushed; then
    if grep -qE "&$host-(sys|user)[[:space:]]" "$sopsYaml" && ! anchorsOk; then
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
    # ── Dépôt de secrets, en premier : la config ne part qu'après lui, sinon
    # la machine autorisée lirait un deployments qui cite des ancres absentes.
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

    # ── Config : deployments et fichiers du host.
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
          # Commit seulement s'il y a quelque chose ; puis l'index est
          # resynchronisé, nixfmt (hook pre-commit) pouvant l'avoir laissé en
          # retard sur l'arbre.
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

# ── Et maintenant ───────────────────────────────────────────────────────────
#
# Destinataire pour de bon dès qu'un fichier cite l'une de ses clés : une
# machine autorisée a rescellé. Sinon, c'est le seul geste qui reste là-bas.
# Le clone est d'abord mis à jour : à la relance, c'est précisément ce
# rescellement, fait depuis l'autre machine, qu'on vient vérifier.
if [ "$github" = 1 ] && [ -d "$secretsRepo/.git" ] \
  && [ -z "$(git -C "$secretsRepo" status --porcelain --untracked-files=no)" ]; then
  git -C "$secretsRepo" pull -q --ff-only 2> /dev/null || true
fi
# Fichiers qui doivent s'ouvrir pour cette machine (leur règle cite une de
# ses ancres) et qui ne la citent pas encore : rescellement à faire.
pendingSeal() {
  local re kind f rel key
  awk -v h="$host" '
    /^# ATTENTION : bloc GÉNÉRÉ/ { gen = 1 }
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

# Règles du bloc généré qui citent cette machine : aucune tant que `secrets
# policy` n'est pas passé sur une machine autorisée — et alors « rien à
# resceller » ne voudrait rien dire.
citedRules() {
  sed -n '/^# ATTENTION : bloc GÉNÉRÉ/,$p' "$sopsYaml" | grep -cE "[*]$host-(sys|user)([[:space:]]|\$)" || true
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
