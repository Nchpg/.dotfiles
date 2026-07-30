# Ouvre des ports sur les interfaces INTERNES seulement, au lieu de les ouvrir
# partout :
#
#   myLib.mkInternalPorts config { tcp = [ 443 ]; }
#
# `networking.firewall.allowedTCPPorts` ouvre sur TOUTES les interfaces,
# présentes et futures. Sur ce parc ça reste sans conséquence uniquement parce
# que deux conditions extérieures tiennent : la box ne redirige aucun port, et
# les annonces de routeur IPv6 sont refusées (cf. modules/system/network). La
# première ne dépend pas de ce dépôt, la seconde tient à une ligne. Ouvrir par
# interface supprime cette dépendance : le jour où l'IPv6 sortante revient, le
# résolveur ne devient pas un résolveur ouvert sur internet et le port SSH ne
# réapparaît pas.
#
# Passe par `extraInputRules` (nft) et non par `networking.firewall.interfaces`,
# qui rend `iifname ${nom}` SANS guillemets : le motif `en*` du module réseau y
# casserait l'analyse de la règle. Ici les guillemets sont posés.
#
# ATTENTION : `extraInputRules` n'existe QUE pour le pare-feu nftables, le
# backend iptables l'ignore en silence — donc les ports seraient fermés sans un
# message. Le module réseau assert que nftables est actif dès que
# `internalIifnames` n'est pas vide.
#
# Liste vide (poste de travail en DHCP) : on retombe sur l'ouverture globale,
# qui reste le bon comportement pour une machine dont les interfaces vont et
# viennent.
#
# La FORME de l'attribut rendu ne dépend pas de `config`, et c'est obligatoire :
# décider ici entre deux jeux de clés différents demande de lire `config` avant
# que les options soient connues, ce que le système de modules solde par une
# récursion infinie. D'où trois clés toujours présentes, dont deux inertes.
lib:

config:

{
  tcp ? [ ],
  udp ? [ ],
}:

let
  iifnames = config.systemSettings.network.internalIifnames;
  perInterface = iifnames != [ ];

  ifaceSet = "{ ${lib.concatMapStringsSep ", " (i: "\"${i}\"") iifnames} }";

  portSet = ports: "{ ${lib.concatMapStringsSep ", " toString ports} }";

  rule =
    proto: ports:
    lib.optionalString (ports != [ ]) ''
      iifname ${ifaceSet} ${proto} dport ${portSet ports} accept
    '';
in
{
  networking.firewall = {
    allowedTCPPorts = lib.mkIf (!perInterface) tcp;
    allowedUDPPorts = lib.mkIf (!perInterface) udp;
    extraInputRules = lib.mkIf perInterface (rule "tcp" tcp + rule "udp" udp);
  };
}
