{
  config,
  lib,
  ...
}:

# Tunnel Cloudflare : publie un service sur internet SANS ouvrir le moindre
# port. `cloudflared` établit une connexion sortante vers l'edge, qui lui
# renvoie ensuite le trafic entrant.
#
# Ce module ne fait PAS la politique d'accès : sans un contrôle devant le nom
# publié (ici Authelia, cf. modules/system/server/authelia), le service est joignable
# par quiconque le découvre — et il se découvre, les certificats émis pour lui
# étant publiés dans les journaux de Certificate Transparency.
let
  cfg = config.systemSettings.cloudflared;
in
{
  options.systemSettings.cloudflared = {
    enable = lib.mkEnableOption "tunnel Cloudflare (accès web sans port ouvert)";

    tunnelId = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "6ff42ae2-765d-4adf-8112-31c55c1551ef";
      description = ''
        UUID du tunnel, tel que renvoyé par `cloudflared tunnel create <nom>`.

        Ce module pilote un tunnel géré LOCALEMENT : les règles d'ingress vivent
        ici, dans le dépôt. Un tunnel créé depuis le tableau de bord Cloudflare
        est géré à distance, ses règles restent chez eux.
      '';
    };

    metricsAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "127.0.0.1:2000";
      description = ''
        Adresse d'écoute de la page `/metrics` du démon, au format `hôte:port`.
        `null` — le défaut — la laisse fermée, comme cloudflared le fait
        lui-même.

        POURQUOI L'OUVRIR : c'est le seul endroit d'où l'on apprend que le tunnel
        a perdu ses connecteurs vers l'edge. L'unité systemd reste `active` dans
        ce cas — le démon tourne, il n'a simplement plus de chemin vers
        internet — et les sondes lancées depuis ce host ne le voient pas non
        plus, les noms publics y étant réécrits vers le LAN par dnsmasq. La panne
        se découvre alors par quelqu'un qui n'arrive pas à ouvrir un service.

        À poser sur la BOUCLE LOCALE : cette page décrit la topologie du tunnel
        et les connexions établies, elle n'a rien à faire sur le réseau.

        L'option vit ICI plutôt que chez celui qui consomme la mesure, parce que
        seul ce module connaît le nom de l'unité à modifier — il est construit
        par le module amont à partir de l'UUID du tunnel.
      '';
    };

    ingress = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        "cloud.exemple.fr" = "https://127.0.0.1:443";
      };
      description = ''
        Nom public vers le service local qui le sert. Le nom est repris tel quel
        en SNI vers l'origine, il doit donc correspondre à un vhost nginx.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.tunnelId != null;
        message = "systemSettings.cloudflared.tunnelId n'est pas renseigné — crée le tunnel avec `cloudflared tunnel create` et reporte l'UUID qu'il affiche.";
      }
      {
        assertion = cfg.ingress != { };
        message = "systemSettings.cloudflared.ingress est vide : le tunnel monterait sans rien router.";
      }
    ];

    # Fichier JSON produit par `cloudflared tunnel create`. Il contient le
    # secret du tunnel : qui l'obtient peut se faire passer pour lui et recevoir
    # le trafic destiné aux noms publics.
    #
    # Aucun `owner` : le module amont le passe au service par LoadCredential,
    # donc systemd le lit en root avant d'abandonner ses privilèges.
    #
    # `restartUnits` n'est PAS décoratif. cloudflared charge ses credentials au
    # démarrage et ne surveille pas le fichier : sans cette ligne, faire tourner
    # le tunnel réécrit /run/secrets sans que le démon le reprenne. Il continue
    # de se présenter avec l'ancien secret, Cloudflare refuse l'enregistrement
    # (« Unauthorized: Invalid tunnel secret »), et l'edge répond 530 faute de
    # connecteur — le tout sans qu'un seul rebuild signale quoi que ce soit.
    # Constaté lors d'une rotation de tunnel.
    sops.secrets."cloudflared/credentials" = {
      restartUnits = lib.optional (cfg.tunnelId != null) "cloudflared-tunnel-${cfg.tunnelId}.service";
    };

    # Le tunnel coupe l'accès public sans qu'aucun certificat soit en cause, et
    # ça ne se voit d'aucune manière depuis la maison — le chemin du LAN et
    # celui du VPN continuent de fonctionner. C'est donc typiquement la panne
    # qu'on découvre par quelqu'un d'autre.
    #
    # Le nom de l'unité est construit par le module amont à partir de l'UUID,
    # d'où l'interpolation plutôt qu'un nom écrit à la main.
    #
    # CE NOM NE SORT PAS D'ICI. Le module de surveillance a besoin d'agir sur la
    # même unité pour lui ouvrir son point de métriques ; il passe par
    # `metricsAddress` ci-dessous et non par le nom, qui est un détail
    # d'implémentation du module amont. Un module extérieur qui écrirait
    # `systemd.services."cloudflared-tunnel-<uuid>"` ne se contenterait pas de
    # cesser de fonctionner le jour où ce nom change : il CRÉERAIT une unité
    # vide portant l'ancien nom, sans que rien ne le signale.
    systemd.services = lib.mkIf (cfg.tunnelId != null) (
      lib.mkMerge [
        (lib.mkIf config.systemSettings.notify.discord.enable {
          "cloudflared-tunnel-${cfg.tunnelId}" = config.systemSettings.notify.discord.onFailure;
        })

        # Ouvre la page de métriques du démon, fermée par défaut.
        #
        # Par l'ENVIRONNEMENT et non par un argument : le module amont écrit son
        # `ExecStart` en dur, et l'écraser avec `mkForce` reviendrait à recopier
        # une ligne de commande qui divergerait en silence à la première mise à
        # jour de nixpkgs. `TUNNEL_METRICS` est la variable que cloudflared
        # associe lui-même à `--metrics` (vérifié dans le binaire).
        (lib.mkIf (cfg.metricsAddress != null) {
          "cloudflared-tunnel-${cfg.tunnelId}".environment.TUNNEL_METRICS = cfg.metricsAddress;
        })
      ]
    );

    services.cloudflared = {
      enable = true;

      # optionalAttrs et pas un `${cfg.tunnelId}` direct : un nom d'attribut
      # s'évalue avant les assertions, un tunnelId nul produirait une erreur
      # d'éval opaque au lieu du message ci-dessus.
      tunnels = lib.optionalAttrs (cfg.tunnelId != null) {
        ${cfg.tunnelId} = {
          credentialsFile = config.sops.secrets."cloudflared/credentials".path;

          ingress = lib.mapAttrs (hostname: service: {
            inherit service;

            originRequest = {
              # Sans SNI explicite, cloudflared se présente à nginx avec
              # l'adresse de bouclage : nginx sert alors son vhost par défaut et
              # le certificat ne correspond à rien.
              originServerName = hostname;

              # En-tête Host forcé, et pas seulement recopié depuis le client :
              # sinon un visiteur pourrait annoncer le nom INTERNE tout en
              # passant par le tunnel et tomber sur la règle d'Authelia qui
              # contourne l'authentification. La route de l'edge ne l'autorise
              # en principe pas, mais la défense ne doit pas tenir à une seule
              # couche.
              httpHostHeader = hostname;
            };
          }) cfg.ingress;

          # Tout ce qui ne correspond à aucune règle est refusé net. Le défaut
          # amont laisserait fuiter des erreurs plus bavardes.
          default = "http_status:404";
        };
      };
    };
  };
}
