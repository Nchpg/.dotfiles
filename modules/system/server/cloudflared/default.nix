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
    systemd.services = lib.mkIf (config.systemSettings.notify.discord.enable && cfg.tunnelId != null) {
      "cloudflared-tunnel-${cfg.tunnelId}" = config.systemSettings.notify.discord.onFailure;
    };

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
