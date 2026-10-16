{
  config,
  lib,
  myLib,
  pkgs-stable,
  ...
}:

let
  cfg = config.systemSettings.monitoring;
  authelia = config.systemSettings.authelia;
  inherit (cfg.internal) ports;
in
{
  config = lib.mkIf cfg.enable {
    services.grafana = {
      enable = true;

      settings = {
        server = {
          http_addr = "127.0.0.1";
          http_port = ports.grafana;
          domain = cfg.grafana.hostName;
          root_url = "https://${cfg.grafana.hostName}/";

          enable_gzip = true;
        };

        analytics = {
          reporting_enabled = false;
          check_for_updates = false;
          feedback_links_enabled = false;
        };
        news.news_feed_enabled = false;

        plugins.check_for_updates = false;

        # En `info`, des milliers de lignes par jour dans le journal.
        log.level = "warn";

        # Sûr tant que Grafana n'écoute que sur 127.0.0.1, que nginx écrase l'en-tête du client
        # (`proxy_set_header`) et que `whitelist` reste la boucle locale.
        "auth.proxy" = {
          enabled = true;
          header_name = "X-WEBAUTH-USER";
          header_property = "username";
          headers = "Name:X-WEBAUTH-NAME Email:X-WEBAUTH-EMAIL";
          auto_sign_up = true;
          sync_ttl = 60;
          whitelist = "127.0.0.1";
          enable_login_token = false;
        };

        auth = {
          # Secours si Authelia ne renvoie plus l'identité : `false` le temps d'un rebuild,
          # puis `grafana-cli admin reset-admin-password`.
          disable_login_form = true;
          disable_signout_menu = true;
        };
        "auth.anonymous".enabled = false;
        "auth.basic".enabled = false;

        users = {
          allow_sign_up = false;

          # `Editor` et non `Admin` : pas d'ajout de source de données, sinon relais de requêtes vers la boucle locale.
          auto_assign_org_role = "Editor";
        };

        security = {
          cookie_secure = true;

          # Engendrée au premier démarrage (preStart) : en clair elle finirait dans le store.
          secret_key = "$__file{${config.services.grafana.dataDir}/secret_key}";
        };
      };

      provision = {
        enable = true;

        datasources.settings = {
          apiVersion = 1;
          datasources = [
            {
              name = "Prometheus";
              type = "prometheus";
              uid = "prometheus";
              access = "proxy";
              url = "http://127.0.0.1:${toString ports.prometheus}";
              isDefault = true;
              jsonData.timeInterval = cfg.scrapeInterval;
            }
            {
              name = "Alertmanager";
              type = "alertmanager";
              uid = "alertmanager";
              access = "proxy";
              url = "http://127.0.0.1:${toString ports.alertmanager}";
              jsonData.implementation = "prometheus";
            }
          ]
          ++ lib.optional cfg.logs.enable {
            name = "Loki";
            type = "loki";
            uid = "loki";
            access = "proxy";
            url = "http://127.0.0.1:${toString ports.loki}";
          };
        };
      };
    };

    services.nginx.virtualHosts.${cfg.grafana.hostName} = lib.mkMerge [
      (myLib.server.mkTlsVhost {
        # Adresse réelle plutôt que 127.0.0.1 (tout arrive par cloudflared).
        extraConfig = ''
          access_log /var/log/nginx/access.log cf_combined;
        '';

        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString ports.grafana}";
          proxyWebsockets = true;

          extraConfig = ''
            # Recopiés de `authelia.nginxProtect` : un niveau qui déclare un `auth_request_set`
            # remplace la liste du parent, et `@authelia_401` servirait un 401 sec.
            auth_request_set $redirection_url $upstream_http_location;
            auth_request_set $auth_status $upstream_status;

            auth_request_set $authelia_user $upstream_http_remote_user;
            auth_request_set $authelia_name $upstream_http_remote_name;
            auth_request_set $authelia_email $upstream_http_remote_email;

            # Écrasent l'en-tête du client : ne jamais retirer tant que `auth.proxy` est actif.
            proxy_set_header X-WEBAUTH-USER $authelia_user;
            proxy_set_header X-WEBAUTH-NAME $authelia_name;
            proxy_set_header X-WEBAUTH-EMAIL $authelia_email;
          '';
        };
      })

      # `nginxProtect` et non `nginxAuthRequest` : la redirection d'Authelia doit être suivie.
      authelia.nginxProtect
    ];

    systemSettings.cloudflared = lib.mkIf cfg.grafana.public {
      ingress.${cfg.grafana.hostName} = "https://127.0.0.1:443";
    };

    # Au premier démarrage seulement : la réécrire rendrait illisible ce qu'elle a chiffré.
    systemd.services.grafana.preStart =
      let
        bin = "${pkgs-stable.coreutils}/bin";
      in
      lib.mkAfter ''
        key=${config.services.grafana.dataDir}/secret_key
        if [ ! -s "$key" ]; then
          umask 077
          # Sans saut de ligne final : Grafana lit le fichier tel quel.
          ${bin}/head -c 32 /dev/urandom \
            | ${bin}/base64 \
            | ${bin}/tr -d '\n' > "$key"
          ${bin}/chmod 0400 "$key"
        fi
      '';

    systemSettings.notify.discord.units = [ "grafana" ];
  };
}
