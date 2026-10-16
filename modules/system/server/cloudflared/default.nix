{
  config,
  lib,
  pkgs-stable,
  ...
}:

let
  cfg = config.systemSettings.cloudflared;

  dnsRoutes = pkgs-stable.writeShellApplication {
    name = "cloudflared-dns";
    runtimeInputs = with pkgs-stable; [
      curl
      jq
      coreutils
    ];
    text = ''
      zone=${lib.escapeShellArg (toString cfg.dnsZone)}
      target=${lib.escapeShellArg "${toString cfg.tunnelId}.cfargotunnel.com"}
      api=https://api.cloudflare.com/client/v4

      # En-tête dans un fichier : un argument de curl est lisible par tous dans /proc.
      umask 077
      auth=$(mktemp)
      trap 'rm -f "$auth"' EXIT
      printf 'Authorization: Bearer %s\n' "$(cat "$CREDENTIALS_DIRECTORY/token")" > "$auth"

      cf() {
        curl --silent --show-error --fail-with-body --max-time 20 \
          --header "@$auth" --header 'Content-Type: application/json' "$@"
      }

      zoneId=$(cf "$api/zones?name=$zone" | jq -er '.result[0].id // empty') || {
        echo "zone $zone introuvable : le jeton doit porter Zone:Read sur elle" >&2
        exit 1
      }

      status=0
      for host in ${lib.escapeShellArgs (lib.attrNames cfg.ingress)}; do
        records=$(cf --get --data-urlencode "name=$host" "$api/zones/$zoneId/dns_records" | jq -c '.result')

        if [ "$(jq 'length' <<< "$records")" -eq 0 ]; then
          jq -n --arg name "$host" --arg content "$target" \
            '{type: "CNAME", $name, $content, proxied: true, comment: "créé par think (cloudflared-dns)"}' \
            | cf --data @- "$api/zones/$zoneId/dns_records" > /dev/null
          echo "$host : CNAME vers le tunnel créé"
        elif jq -e --arg t "$target" 'any(.type == "CNAME" and .content == $t)' <<< "$records" > /dev/null; then
          echo "$host : ok"
        else
          echo "$host : déjà pris par $(jq -r 'map("\(.type) \(.content)") | join(", ")' <<< "$records"), laissé tel quel" >&2
          status=1
        fi
      done

      exit "$status"
    '';
  };
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
      '';
    };

    metricsAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "127.0.0.1:2000";
      description = ''
        Adresse `hôte:port` de la page `/metrics` du démon (fermée si `null`).
      '';
    };

    dnsZone = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "exemple.fr";
      description = ''
        Zone Cloudflare où créer le CNAME de chaque nom de `ingress` vers le tunnel
        (`null` : rien, `cloudflared tunnel route dns` à la main). Ne crée que des
        enregistrements absents : un nom déjà pris par autre chose fait échouer l'unité,
        sans rien modifier. Jeton `cloudflare/api_token` (Zone:Read, DNS:Edit).
      '';
    };

    ingress = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        "cloud.exemple.fr" = "https://127.0.0.1:443";
      };
      description = ''
        Nom public vers le service local qui le sert ; repris en SNI, il doit correspondre à un vhost nginx.
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
      {
        assertion =
          cfg.dnsZone == null
          || lib.all (h: h == cfg.dnsZone || lib.hasSuffix ".${cfg.dnsZone}" h) (lib.attrNames cfg.ingress);
        message = "systemSettings.cloudflared.dnsZone : ces noms sont hors de la zone ${toString cfg.dnsZone} : ${
          toString (
            lib.filter (h: h != cfg.dnsZone && !lib.hasSuffix ".${toString cfg.dnsZone}" h) (
              lib.attrNames cfg.ingress
            )
          )
        }.";
      }
    ];

    # Même jeton que le DNS-01 d'ACME (module proxy) ; déclaré ici aussi pour ne pas en dépendre.
    sops.secrets."cloudflare/api_token" = lib.mkIf (cfg.dnsZone != null) { };

    systemd.services.cloudflared-dns = lib.mkIf (cfg.dnsZone != null && cfg.tunnelId != null) {
      description = "CNAME Cloudflare des noms publiés par le tunnel";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      # Le script embarque la liste des noms : un nom ajouté relance l'unité au switch.
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe dnsRoutes;
        LoadCredential = "token:${config.sops.secrets."cloudflare/api_token".path}";

        # Réseau pas encore prêt au boot : quelques essais avant de signaler.
        Restart = "on-failure";
        RestartSec = "2min";

        DynamicUser = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectHome = true;
        PrivateDevices = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
      };
      unitConfig = {
        StartLimitBurst = 4;
        StartLimitIntervalSec = "1h";
      };
    };

    # Pas d'owner : le module amont passe le fichier par LoadCredential.
    # restartUnits : cloudflared ne recharge pas ses credentials (530 silencieux).
    sops.secrets."cloudflared/credentials" = {
      restartUnits = lib.optional (cfg.tunnelId != null) "cloudflared-tunnel-${cfg.tunnelId}.service";
    };

    # Le tunnel abandonne si la résolution de l'edge échoue au boot : après dnsmasq.
    systemSettings = lib.mkIf (cfg.tunnelId != null) {
      notify.discord.units = [
        "cloudflared-tunnel-${cfg.tunnelId}"
      ]
      ++ lib.optional (cfg.dnsZone != null) "cloudflared-dns";
      dns.dependentUnits = [
        "cloudflared-tunnel-${cfg.tunnelId}"
      ]
      ++ lib.optional (cfg.dnsZone != null) "cloudflared-dns";
    };

    # Par l'environnement : le module amont fixe son ExecStart.
    systemd.services."cloudflared-tunnel-${toString cfg.tunnelId}" = lib.mkIf (
      cfg.tunnelId != null && cfg.metricsAddress != null
    ) { environment.TUNNEL_METRICS = cfg.metricsAddress; };

    services.cloudflared = {
      enable = true;

      # Un nom d'attribut s'évalue avant les assertions.
      tunnels = lib.optionalAttrs (cfg.tunnelId != null) {
        ${cfg.tunnelId} = {
          credentialsFile = config.sops.secrets."cloudflared/credentials".path;

          ingress = lib.mapAttrs (hostname: service: {
            inherit service;

            originRequest = {
              originServerName = hostname;

              # Empêche d'annoncer le nom interne pour tomber sur la règle Authelia sans authentification.
              httpHostHeader = hostname;
            };
          }) cfg.ingress;

          default = "http_status:404";
        };
      };
    };
  };
}
