#!/usr/bin/env bash
# Enrôle une machine neuve : ce qu'il faut poser AVANT le premier rebuild, dans
# le bon ordre et surtout avec les bons droits.
#
# Pourquoi un script plutôt qu'une section de doc : ce sont les MODES de fichiers
# qui se trompent quand un humain suit une procédure. `/var/lib/nix` en 0700 au
# lieu de 0755 paraît plus prudent et casse silencieusement toute la
# configuration nix des utilisateurs non root — nix n'ignore pas un include
# qu'il ne peut pas atteindre, il jette /etc/nix/nix.conf en entier. Constaté.
#
# Chaque étape est IDEMPOTENTE : relancer le script ne réécrit rien de ce qui
# existe déjà. Il ne touche jamais à un secret en place.
#
# Ce qu'il NE PEUT PAS faire : s'autoriser lui-même. Une machine neuve fabrique
# sa clé, mais c'est une machine DÉJÀ autorisée qui doit l'ajouter aux
# destinataires. Le script s'arrête donc en disant quoi faire, et où.
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
skip() { echo -e "${YELLOW}·${NC} $*"; }
die()  { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "à lancer en tant qu'utilisateur : le script appelle sudo lui-même."

flake="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$flake/flake.nix" ] || die "$flake ne ressemble pas au dépôt (pas de flake.nix)."

secretsRepo="${MY_SECRETS:-$HOME/.secrets}"
secretsUrl="${MY_SECRETS_URL:-git@github.com:Nchpg/secrets.git}"

echo "🔧 Enrôlement de $(hostname) — dépôt : $flake"
echo
sudo -v || die "sudo requis."

# ── 1. Jeton de lecture du dépôt de secrets ─────────────────────────────────
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
  read -rsp "   Jeton : " token; echo
  [ -n "$token" ] || die "jeton vide."
  # Par un tuyau : ni argv, ni environnement, ni historique de shell.
  printf 'access-tokens = github.com=%s\n' "$token" \
    | sudo sh -c "umask 077; cat > '$tokenFile'"
  unset token
  ok "jeton écrit dans $tokenFile (0600 root)"
fi

# ── 2. Clé système, pour les secrets lus par root ───────────────────────────
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
  agePkg="$(nix --extra-experimental-features 'nix-command flakes' \
    build --no-link --print-out-paths nixpkgs#age)" \
    || die "impossible de récupérer age depuis nixpkgs."
  ageKeygen="$agePkg/bin/age-keygen"
fi

sysKey=/var/lib/sops-nix/key.txt
sudo install -d -m 755 /var/lib/sops-nix
if sudo test -f "$sysKey"; then
  skip "clé système déjà présente ($sysKey)"
else
  sudo sh -c "umask 077; '$ageKeygen' -pq -o '$sysKey'" \
    || die "génération de la clé système échouée."
  ok "clé système hybride (ML-KEM-768 + X25519) générée ($sysKey)"
fi
# Uniquement les destinataires HYBRIDES. `age-keygen -y` liste TOUTES les
# identités du fichier, et les machines migrées gardent leur ancienne clé
# classique à côté de la nouvelle : afficher les deux ferait enrôler la mauvaise,
# ce qui casserait la propriété post-quantique sans un message.
sysPub="$(sudo "$ageKeygen" -y "$sysKey" 2> /dev/null | grep '^age1pq1' || true)"

# ── 3. Clé utilisateur, pour tes propres secrets ────────────────────────────
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
userPub=""
if [ -f "$userKey" ]; then
  userPub="$("$ageKeygen" -y "$userKey" 2> /dev/null | grep '^age1pq1' || true)"
fi

# ── 4. Dépôt privé des secrets ──────────────────────────────────────────────
if [ -d "$secretsRepo/.git" ]; then
  skip "dépôt de secrets déjà cloné ($secretsRepo)"
elif git clone "$secretsUrl" "$secretsRepo"; then
  ok "dépôt de secrets cloné dans $secretsRepo"
else
  echo -e "${YELLOW}·${NC} clone échoué — sans lui, la commande \`secrets\` ne trouvera rien."
  echo "   À refaire : git clone $secretsUrl $secretsRepo"
fi

# ── Ce que le script ne peut pas faire ──────────────────────────────────────
echo
echo "── il reste DEUX choses, depuis une machine DÉJÀ autorisée ──"
echo
if [ -n "$sysPub" ]; then
  echo "  clé système de cette machine   : $sysPub"
fi
if [ -n "$userPub" ]; then
  echo "  clé utilisateur de ce compte   : $userPub"
fi
cat <<INSTRUCTIONS

  1. Ajouter ces clés dans .sops.yaml du dépôt de secrets, la système sous le
     groupe de system.yaml, l'utilisateur sous celui de secrets.yaml.
  2. Lancer \`secrets updatekeys\` LÀ-BAS, pas ici : resceller un fichier exige
     de pouvoir déjà le déchiffrer.

  Ensuite, ici : ./rebuild.sh

INSTRUCTIONS
