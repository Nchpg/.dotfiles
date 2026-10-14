# shellcheck shell=bash disable=SC2154 # private_key_path, dns_line, endpoint, allowed_ips : posés par le préambule Nix
# wg-new-peer : fabrique une configuration cliente complète, QR compris, sans
# jamais écrire la clé privée où que ce soit — elle ne traverse que la sortie
# du terminal. C'est le remplaçant direct de l'interface d'appairage.
#
# Corps du script seulement : le module (default.nix à côté) le précède d'un
# préambule qui pose `private_key_path`, `dns_line`, `endpoint` et
# `allowed_ips` d'après sa configuration.

if [ $# -lt 2 ]; then
  cat >&2 <<'USAGE'
usage: wg-new-peer <nom> <adresse-dans-le-tunnel>

  wg-new-peer telephone-nathan 10.8.0.2

Affiche la configuration cliente et son QR code, puis l'extrait Nix à
coller dans le profil. La clé privée n'est écrite nulle part : copie-la
depuis ce terminal, ou scanne le QR, et referme.

À lancer en root : la clé publique du serveur est dérivée de sa clé privée.
USAGE
  exit 2
fi

name=$1
address=$2

if [ ! -r "$private_key_path" ]; then
  echo "impossible de lire $private_key_path — relance en root" >&2
  exit 1
fi

server_public=$(wg pubkey < "$private_key_path")
private=$(wg genkey)
public=$(printf '%s' "$private" | wg pubkey)
psk=$(wg genpsk)

conf=$(cat <<CONF
[Interface]
PrivateKey = $private
Address = $address/32
$dns_line

[Peer]
PublicKey = $server_public
PresharedKey = $psk
Endpoint = $endpoint
AllowedIPs = $allowed_ips
# Les clients mobiles passent derrière un NAT opérateur qui ferme les
# associations UDP inactives en ~30 s : sans keepalive, le tunnel semble
# « mort » jusqu'à ce que le téléphone émette de lui-même.
PersistentKeepalive = 25
CONF
)

printf '%s\n' "$conf"
echo
echo "── QR (à scanner depuis l'application WireGuard) ──"
printf '%s' "$conf" | qrencode -t ansiutf8
echo
echo "── 1. à ranger dans les secrets SYSTÈME ──"
echo "     secrets edit wireguard/${name}_preshared_key"
cat <<SECRET
wireguard:
  ${name}_preshared_key: $psk
SECRET
echo
echo "── 2. à ajouter dans profiles/server/vpn.nix, puis nixos-rebuild switch ──"
cat <<PEER
{
  name = "$name";
  publicKey = "$public";
  address = "$address";
  presharedKeyKey = "wireguard/${name}_preshared_key";
}
PEER
echo
echo "L'ORDRE COMPTE : le secret sops doit exister AVANT le rebuild, sinon"
echo "l'activation échoue faute de pouvoir déchiffrer la clé pré-partagée."
echo "Tant que le rebuild n'est pas fait, ce peer n'est pas autorisé."
