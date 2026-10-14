{ ... }:

# VPN WireGuard servi par ce host.
let
  domain = import ./domain.nix;
in
{
  systemSettings = {
    # Accès distant aux services de la maison SANS en exposer aucun sur
    # internet : seul le port UDP de WireGuard est redirigé sur la box, tout le
    # reste ne répond que sur le LAN ou dans le tunnel.
    #
    # WireGuard natif et non wg-easy : les clés privées des appareils ne
    # transitent jamais par ce host, chaque peer garde son adresse propre — donc
    # une règle Authelia par appareil est possible — et il n'y a plus ni démon
    # docker, ni image à suivre, ni interface web à tenir à jour. L'appairage se
    # fait par `sudo wg-new-peer <nom> <adresse>`, qui affiche la configuration
    # et son QR code.
    vpn.wireguard = {
      enable = true;
      # Sous-domaine dédié, et surtout en « DNS only » côté Cloudflare : leur
      # proxy ne relaie que HTTP/HTTPS, un enregistrement proxifié ne peut pas
      # porter l'UDP de WireGuard. L'apex est pris par le site et un wildcard
      # renverrait vers CF, d'où un record explicite qui l'emporte sur lui.
      host = "vpn.${domain}";

      # AUCUN résolveur poussé, comme pour gram : chaque appareil garde le
      # sien, et `cloud.vpn.` résout partout par son enregistrement A public
      # vers 10.8.0.1. C'est ce qui fait qu'un peer ne dépend plus de dnsmasq.
      #
      # La liste précédente était `[ think, la box ]`, censée dégrader
      # gracieusement si dnsmasq s'arrêtait. Elle ne le pouvait pas : la box
      # est sur le LAN, donc joignable seulement en TRAVERSANT ce host, et la
      # règle de forward exclut toutes les destinations privées tandis que
      # `peerLanAccess` est vide. Le repli était jeté en silence, et une panne
      # de dnsmasq coupait TOUTE résolution sur un appareil en tunnel complet,
      # pas seulement les réécritures.
      dns = [ ];

      # Seul le réseau du tunnel y passe, comme gram (cf. hosts/gram). Le
      # trafic ordinaire d'un appareil sort par le réseau où il se trouve.
      #
      # C'est ce que le commentaire de `nextcloud.extraHostNames` plus bas
      # décrit déjà comme le modèle en place — « les clients ne routent que
      # 10.8.0.0/24 vers le VPN » — et qui n'était vrai que de gram. Les
      # profils fabriqués ici partaient encore sur le défaut du module, un
      # tunnel COMPLET, hérité de wg-easy.
      #
      # Ce qu'on abandonne : le chiffrement du trafic ordinaire sur un WiFi
      # public, et l'URL unique — le client de synchronisation d'un peer doit
      # viser `cloud.vpn.…` et non `cloud.…`, ce dernier passant désormais par
      # le portail depuis l'extérieur. En échange le tunnel peut rester monté
      # en permanence sans détourner le trafic ni dépendre de l'upload de la
      # box, et think éteinte ne coupe plus internet.
      #
      # `::/0` disparaît avec, et c'est cohérent : il ne servait qu'à colmater
      # la fuite IPv6 d'un tunnel complet. Sans tunnel complet, il n'y a plus
      # rien à colmater.
      allowedIPs = [ "10.8.0.0/24" ];

      # Un appareil par entrée, clé PUBLIQUE seulement. Retirer une entrée
      # révoque l'appareil au prochain rebuild — la révocation redevient
      # déclarative, ce qu'elle n'était pas quand la liste vivait dans le volume
      # de wg-easy.
      #
      # Les adresses se prennent à la suite dans la plage, 10.8.0.1 étant le
      # serveur. Le nom n'est lu que par nous ; c'est l'adresse et la clé qui
      # comptent, et une assertion du module refuse un doublon.
      peers = [
        {
          name = "xiaomi_17t";
          trusted = true;
          publicKey = "2XpsKYhyyKszaFd91V8cQ7yynz04RZ37S040S2OU5DY=";
          address = "10.8.0.2";
          presharedKeyKey = "wireguard/xiaomi_17t_preshared_key";
        }
        {
          name = "gram";
          trusted = true;
          publicKey = "/gV7axgKpUvtPD/oEnbgC4CFpvRULEMAmGVekD4B/zI=";
          address = "10.8.0.3";
          presharedKeyKey = "wireguard/gram_preshared_key";
        }
        {
          name = "windows_gram";
          trusted = true;
          publicKey = "9q/Vrdgd2Q+o+GWGi8GePNlbQM9lLJ9SNNKwVWHDsWs=";
          address = "10.8.0.4";
          presharedKeyKey = "wireguard/windows_gram_preshared_key";
        }
        {
          name = "oppo_a74";
          publicKey = "gSR1i2a2jxgn3yeszMLjFMe8n+fXOTrFPMuvy0gEhko=";
          address = "10.8.0.5";
          presharedKeyKey = "wireguard/oppo_a74_preshared_key";
        }
        {
          name = "xiaomi_9t";
          publicKey = "hcqtv8ay9e0DKE1qRxWc4+FW2JAiDkWYTbiMIjfPJCE=";
          address = "10.8.0.6";
          presharedKeyKey = "wireguard/xiaomi_9t_preshared_key";
        }
        {
          name = "xiaomi_14tpro";
          publicKey = "pJ7CyK5txL/l2lVqsJ7cD+VGa69WOPy7ixGH7DtIDH0=";
          address = "10.8.0.7";
          presharedKeyKey = "wireguard/xiaomi_14tpro_preshared_key";
        }
        {
          name = "lenovo_tab_p12";
          publicKey = "AyLyEp/YhPJaLNMwIfyZibWt6XymReCgVUXLLQ6JqXs=";
          address = "10.8.0.8";
          presharedKeyKey = "wireguard/lenovo_tab_p12_preshared_key";
        }
      ];

      # SORTIE INTERNET COUPÉE, et c'est la conséquence directe du passage au
      # tunnel restreint juste au-dessus.
      #
      # Tant que `allowedIPs` valait `0.0.0.0/0`, cette option était le sens
      # même du montage : tout sortait par la maison, donc il fallait bien
      # laisser passer. Depuis qu'on ne pousse plus que `10.8.0.0/24`, aucun
      # peer n'envoie de trafic ordinaire dans le tunnel — la règle de forward
      # restait donc posée sans que rien ne l'emprunte, c'est-à-dire comme
      # surface et rien d'autre. Un appareil compromis pouvait encore ajouter
      # la route lui-même et se servir de la maison comme nœud de sortie, avec
      # du trafic attribuable à cette connexion.
      #
      # CE QUE ÇA N'AFFECTE PAS : les services de ce host. Nextcloud, le DNS
      # et SSH sont délivrés LOCALEMENT et relèvent du pare-feu d'entrée, pas
      # de la chaîne de forward — un peer continue de les joindre exactement
      # comme avant.
      #
      # PRÉCONDITION, à vérifier avant de rebuild : un appareil appairé du
      # temps où `wg-new-peer` fabriquait des profils en tunnel complet porte
      # encore `AllowedIPs = 0.0.0.0/0` dans SA configuration, et perdrait
      # alors tout internet tant que son tunnel est monté. Les profils
      # existants ne se mettent pas à jour tout seuls. Regénérer le profil de
      # l'appareil concerné, ou remettre cette ligne à `true` le temps de le
      # faire.
      peerInternetAccess = false;

      # Un peer n'atteint sur le LAN que cette machine — pas la box, pas les
      # objets connectés. Liste VIDE et non « tout le /24 » : un téléphone
      # familial compromis ne doit pas être un pied dans la maison.
      #
      # Ce filtrage n'existait pas avant : avec le pare-feu en iptables, la
      # chaîne FORWARD n'était filtrée par rien du tout.
      #
      # Rien à ajouter ici pour Nextcloud, le DNS ou SSH : ils tournent SUR ce
      # host, donc leur trafic est délivré localement et relève du pare-feu
      # d'entrée, pas du filtrage de traversée.
      peerLanAccess = [ ];
    };
  };
}
