{
  config,
  lib,
  myLib,
  ...
}:

# Résolveur local à horizon partagé : il répond une adresse du LAN pour des noms
# qui, vus d'internet, pointent ailleurs.
#
# C'est ce qui permet UNE seule URL partout. À la maison et dans le VPN,
# `cloud.…` va droit à nginx et Authelia laisse passer ; depuis l'extérieur, le
# même nom passe par le tunnel et le portail. Sans ça il faut deux noms, et un
# lien de partage créé depuis le nom interne est inutilisable par son
# destinataire, son contenu étant construit d'après l'hôte de la requête.
#
# À PESER : dès que la box distribue cette machine comme résolveur, plus rien ne
# résout dans la maison quand elle s'arrête. Pour les clients WireGuard, à qui
# on pousse la liste directement, un second résolveur en repli réduit le risque
# (cf. systemSettings.vpn.wireguard.dns).
let
  cfg = config.systemSettings.dns;
  static = config.systemSettings.network.staticIPv4;
in
{
  options.systemSettings.dns = {
    enable = lib.mkEnableOption "résolveur local dnsmasq (DNS à horizon partagé)";

    overrides = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        "cloud.exemple.fr" = "192.168.1.32";
      };
      description = ''
        Nom vers l'adresse à répondre localement, en lieu et place de ce que dit
        le DNS public.

        ATTENTION à la portée : la syntaxe de dnsmasq couvre le nom ET TOUS ses
        sous-domaines. Réécrire `cloud.exemple.fr` détourne donc aussi
        `quoiquecesoit.cloud.exemple.fr`, y compris un service qu'on hébergerait
        ailleurs plus tard.
      '';
    };

    upstreams = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "1.1.1.1"
        "9.9.9.9"
      ];
      description = ''
        Résolveurs interrogés pour tout le reste. Volontairement PUBLICS et non
        la box : celle-ci peut distribuer dnsmasq comme résolveur du LAN, et se
        prendre pour amont ferait une boucle.
      '';
    };

    rebindOkDomains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "vpn.exemple.fr" ];
      description = ''
        Noms autorisés à répondre une adresse PRIVÉE depuis l'amont, eux et
        leurs sous-domaines.

        Ce module refuse ces réponses par défaut (`stop-dns-rebind`), parce
        qu'un site visité depuis la maison peut sinon faire pointer son propre
        nom vers une adresse du LAN et se servir du navigateur pour l'atteindre
        — ce qui compte double ici, la règle d'Authelia contournant le portail
        pour tout le sous-réseau de la maison.

        Il faut donc lister les noms qui font ÇA légitimement, sans quoi ils
        cessent de résoudre. Le cas de ce parc : le nom du chemin réservé, dont
        l'enregistrement A public pointe vers l'adresse du serveur dans le
        tunnel. Les noms réécrits localement (`overrides`) ne sont PAS
        concernés, la réponse ne venant pas de l'amont.
      '';
    };

    dependentUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "cloudflared-tunnel-<uuid>" ];
      description = ''
        Services systemd (sans `.service`) à démarrer APRÈS dnsmasq, parce que la
        première chose qu'ils font est de résoudre un nom. Chaque module y ajoute
        les siens sans condition : sans effet tant que ce résolveur n'est pas
        activé.

        `network-online.target` garantit une adresse, pas un DNS qui répond, et
        dnsmasq n'est pas forcément debout quand elle est atteinte. Ce qu'on
        pose est un ORDRE (`after` + `wants`) et non une dépendance dure : si
        dnsmasq est absent ou tombe plus tard, ces services vivent leur vie.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # Le résolveur répond au LAN et au tunnel, jamais à internet. Le distinguo
      # n'est pas théorique : un résolveur récursif joignable de l'extérieur sert
      # à amplifier des attaques par déni de service, et le seul rempart
      # aujourd'hui est que la box ne redirige pas le port 53.
      (myLib.mkInternalPorts config {
        tcp = [ 53 ];
        udp = [ 53 ];
      })

      {
        assertions = [
          {
            assertion = static != null;
            message = "systemSettings.dns exige un adressage statique : un résolveur doit répondre à une adresse qui ne bouge pas.";
          }
        ];

        services.dnsmasq = {
          enable = true;

          # `always` au lieu du `on-failure` par défaut, via l'option dédiée — le
          # module amont pose `Restart` en dur, une seconde définition entrerait en
          # conflit.
          #
          # Ce qui compte n'est pas tant `always` que le `RestartSec` posé juste en
          # dessous : les défauts sont 100 ms entre deux tentatives et cinq
          # tentatives par fenêtre de dix secondes, si bien qu'une contrariété
          # passagère d'une seconde épuise le budget et laisse l'unité MORTE
          # définitivement, jusqu'à intervention manuelle. Sur le seul résolveur de
          # la maison, ça se solde par « plus rien ne résout » et personne ne sait
          # pourquoi.
          alwaysKeepRunning = true;

          settings = {
            # Adresses EXPLICITES, jamais 0.0.0.0 : systemd-resolved occupe déjà
            # 127.0.0.53 et 127.0.0.54, une liaison globale entrerait en conflit.
            #
            # L'adresse du LAN sert les clients de la maison, et les clients
            # WireGuard : on la leur pousse comme résolveur, leurs requêtes arrivent
            # donc avec elle en destination, quel que soit le pont docker traversé.
            #
            # `127.0.0.1` est indispensable, et l'oublier échoue SANS BRUIT. Le
            # module amont pose `resolveLocalQueries = true` par défaut, ce qui écrit
            # `networking.nameservers = [ "127.0.0.1" ]` : sans écoute sur la boucle
            # locale, le host interroge un port fermé et resolved bascule sur ses
            # serveurs de secours compilés (1.1.1.1, 8.8.8.8, …). Symptôme observé :
            # un nom réécrit ici échouait à résoudre sur la machine même qui le sert,
            # et aucune réécriture de ce module ne s'appliquait localement.
            listen-address = [
              "127.0.0.1"
              static.address
            ];
            bind-interfaces = true;

            # La syntaxe /nom/adresse couvre le nom ET ses sous-domaines.
            address = lib.mapAttrsToList (name: addr: "/${name}/${addr}") cfg.overrides;

            # INDISPENSABLE, et son absence produit la panne la plus déroutante du
            # montage : `address=` ne réécrit que les enregistrements A. Les AAAA
            # continuaient d'être transmis en amont, donc un nom réécrit répondait
            # 192.168.1.32 en IPv4 ET les adresses de Cloudflare en IPv6.
            #
            # Conséquence sur un client double pile, qui préfère IPv6 : il repartait
            # par l'edge et le tunnel malgré la réécriture, tombait sur la règle
            # `two_factor` d'Authelia, et le client Nextcloud échouait sur une
            # « erreur inattendue » — alors que `dig A` semblait confirmer que tout
            # allait bien. Constaté depuis gram ; think y échappait par accident,
            # n'ayant plus d'IPv6 globale.
            #
            # `local=` interdit à dnsmasq de transmettre ces noms en amont : il
            # répond alors NODATA sur les types qu'il n'a pas, au lieu d'aller
            # chercher ailleurs. Vérifié : A répond, AAAA renvoie NOERROR sans
            # réponse, et les autres noms gardent leur IPv6.
            #
            # Préféré à `filter-AAAA`, qui aurait supprimé l'IPv6 de TOUTES les
            # résolutions de la maison, et à `address=/nom/::`, dont le `::` est
            # souvent interprété comme la boucle locale par les clients.
            local = lib.mapAttrsToList (name: _: "/${name}/") cfg.overrides;

            server = cfg.upstreams;

            # Filtre les enregistrements SVCB (64) et HTTPS (65), INDISPENSABLE dès
            # qu'on réécrit un nom servi par Cloudflare : leur enregistrement HTTPS
            # porte une configuration ECH et des `ipv4hint` vers leurs serveurs.
            # Réécrire le A sans le supprimer laisse le navigateur avec deux
            # consignes contradictoires — « connecte-toi à 192.168.1.32 » et
            # « chiffre le ClientHello avec les clés de Cloudflare ». Chrome tente
            # l'ECH, échoue, et refuse sur ERR_ECH_FALLBACK_CERTIFICATE_INVALID.
            #
            # Portée assumée : dnsmasq ne sait pas filtrer par nom, donc aucun
            # client de ce résolveur n'aura d'ECH ni de découverte HTTP/3 par le
            # DNS. Le premier ne masquait le nom du site qu'aux yeux du réseau
            # local, le second se retrouve par l'en-tête Alt-Svc.
            filter-rr = [
              "64"
              "65"
            ];

            # Ne lit pas /etc/resolv.conf pour trouver ses amonts : ce fichier est
            # écrit par resolved et pointe sur la boucle locale, donc sur dnsmasq
            # lui-même une fois la configuration en place.
            no-resolv = true;

            domain-needed = true;
            bogus-priv = true;

            # Rejette une réponse d'amont qui pointe vers une adresse privée. Sans
            # ça, un nom contrôlé par un tiers peut répondre 192.168.1.32 et faire
            # émettre des requêtes vers la maison par le navigateur de celui qui
            # visite le site, depuis l'intérieur du réseau — donc en tombant du bon
            # côté des règles qui distinguent « vient du LAN ».
            #
            # `rebind-localhost-ok` garde 127.0.0.0/8 hors du filtre : resolved et
            # les services locaux en dépendent.
            stop-dns-rebind = true;
            rebind-localhost-ok = true;
            rebind-domain-ok = map (domain: "/${domain}/") cfg.rebindOkDomains;
          };
        };

        # ATTENDRE QUE L'ADRESSE EXISTE. Le module amont n'ordonne dnsmasq que
        # sur `network.target`, qui signifie « la configuration réseau a été
        # LANCÉE », pas « les adresses sont posées ». Or dnsmasq écoute
        # explicitement sur l'adresse statique, et une écoute sur une adresse
        # absente échoue net :
        #
        #   failed to create listening socket for 192.168.1.32:
        #   Cannot assign requested address
        #
        # C'est ce qui s'est produit au redémarrage du 16 août — première
        # tentative à 04:49:59, réussie seulement à 04:50:05, six secondes
        # pendant lesquelles la machine n'avait aucun résolveur. `Restart=always`
        # rattrapait, au prix d'une fenêtre aveugle et d'une alerte en cascade
        # sur tout ce qui a besoin du DNS au démarrage.
        #
        # `network-online.target` est atteint quand systemd-networkd a fini de
        # configurer les liens, adresses comprises.
        systemd.services = {
          dnsmasq = {
            after = [ "network-online.target" ];
            wants = [ "network-online.target" ];

            # Cinq secondes entre deux tentatives, contre 100 ms par défaut :
            # avec cet espacement, cinq redémarrages s'étalent sur vingt-cinq
            # secondes et ne tiennent donc jamais dans la fenêtre de dix
            # secondes du `StartLimitBurst`. L'unité continue d'essayer au lieu
            # d'abandonner.
            serviceConfig.RestartSec = 5;
          };
        }
        // lib.genAttrs cfg.dependentUnits (_: {
          after = [ "dnsmasq.service" ];
          wants = [ "dnsmasq.service" ];
        });
      }
    ]
  );
}
