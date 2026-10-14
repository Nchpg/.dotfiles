{ config, ... }:

# Résolveur local à horizon partagé.
let
  domain = import ./domain.nix;
  lanIp = config.systemSettings.network.staticIPv4.address;
in
{
  systemSettings = {
    # Réécriture locale : cloud. répond l'adresse du LAN à la maison et dans le
    # VPN, le tunnel ailleurs. C'est ce qui permet UNE seule URL partout, y
    # compris dans les applications et les liens de partage, ceux-ci étant
    # construits d'après l'hôte de la requête en cours.
    dns = {
      enable = true;

      # Le SEUL nom qui a une raison légitime de répondre une adresse privée
      # depuis l'amont : `cloud.vpn.` pointe vers 10.8.0.1 par un
      # enregistrement A public. Sans cette exemption, la protection contre le
      # rebinding le rejetterait et le chemin de synchronisation tomberait.
      rebindOkDomains = [ "vpn.${domain}" ];

      # Les noms SERVIS ici (`cloud.`, `auth.`, `metrics.`) n'y figurent plus :
      # leur réécriture vers le LAN découle de leur publication (`lanShortcut`
      # dans `systemSettings.proxy.sites`), déclarée par le module qui les sert.
      overrides = {
        # TOUTE la zone interne, résolue ICI et nulle part ailleurs. La syntaxe
        # de dnsmasq couvrant le nom et ses sous-domaines, cette entrée
        # remplace à elle seule le joker `*.lan.` qui vivait chez Cloudflare :
        # n'importe quel nom interne répond, sans rien avoir à déclarer.
        #
        # Plus aucun service du profil n'en dépend depuis le retrait de
        # `cloud.lan.` et de `wg.lan.`, mais elle reste utile pour les noms ad
        # hoc — `think.lan.…` pour SSH, par exemple.
        #
        # Pourquoi l'avoir retiré du DNS public : cet enregistrement publiait
        # 192.168.1.32 au monde entier, et le suffixe `.lan.` ne protégeait
        # rien — c'est un label ordinaire sous une zone publique, pas un
        # domaine local. Le nom ne donnait aucun accès (adresse non routable),
        # mais il n'avait aucune raison d'être annoncé.
        #
        # CE QUE ÇA COÛTE : le DNS public ne sert plus de filet. Si dnsmasq
        # s'arrête, les noms internes deviennent irrésolvables partout, y
        # compris pour les clients VPN — leur résolveur de repli est la box,
        # qui ne les connaît pas. Le chemin public de Nextcloud (`cloud.`,
        # par le tunnel) continue de fonctionner, lui.
        #
        # Les certificats ne sont pas concernés : la validation est en DNS-01,
        # lego pose un TXT par l'API Cloudflare sans avoir besoin d'un
        # enregistrement A, et vérifie la propagation chez 1.1.1.1 (cf.
        # `dnsResolver` dans modules/system/server/proxy) et non chez dnsmasq, qui
        # répondrait NODATA sur ces noms-là.
        "lan.${domain}" = lanIp;
      };
    };
  };
}
