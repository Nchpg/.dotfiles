{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.systemSettings.nextcloud;
  authelia = config.systemSettings.authelia;

  phpLocation = config.services.nginx.virtualHosts.${cfg.hostName}.locations."~ \\.php(?:$|/)";
in
{
  config = lib.mkIf cfg.enable {
    # Journal des visites (onglet Trafic) : le compte tapé dans le formulaire de connexion, seul (le
    # mot de passe n'est jamais extrait) ; Vector ne le garde que pour l'envoi de ce formulaire.
    systemSettings.proxy.visits.fields.form_user = "$nextcloud_form_user";

    services.nginx.commonHttpConfig = lib.mkMerge [
      ''
        map $request_body $nextcloud_form_user {
          default                     "";
          "~(?:^|&)user=(?<u>[^&]*)"  $u;
        }
      ''

      # `$request_uri` et non `$uri` : le `try_files` de la location PHP réécrit `$uri` avant FastCGI.
      (lib.mkIf (cfg.publicSharing.enable && cfg.publicSharing.canonicalLinkHost) ''
        map $request_uri $nextcloud_link_host {
          default $http_host;
        ${lib.concatMapStrings (path: "  ${path} ${cfg.hostName};\n") cfg.publicSharing.canonicalLinkPaths}}
      '')

      # `mkAfter` : `$real_client_ip` doit être définie avant.
      (lib.mkIf (cfg.publicSharing.enable && cfg.publicSharing.rateLimit.enable) (
        lib.mkAfter ''
          # `volatile` + `$uri` : la redirection interne ne doit pas compter deux fois la requête.
          # Une clé vide désactive la limite.
          map $uri $nextcloud_share_client {
            volatile;
            default         "";
            ~^/s/           $real_client_ip;
            ~^/public\.php  $real_client_ip;
          }

          map $uri $nextcloud_preview_client {
            volatile;
            default                                              "";
            ~^/(?:index\.php/)?apps/files_sharing/publicpreview  $real_client_ip;
          }

          limit_req_zone $nextcloud_share_client zone=nextcloud_share:10m rate=${cfg.publicSharing.rateLimit.rate};
          limit_req_zone $nextcloud_preview_client zone=nextcloud_preview:10m rate=${cfg.publicSharing.rateLimit.previewRate};
        ''
      ))
    ];

    services.nginx.virtualHosts.${cfg.hostName} = lib.mkMerge [
      (myLib.server.mkTlsVhost { serverAliases = cfg.extraHostNames; })

      # Au niveau serveur : plusieurs locations amont servent ces chemins.
      (lib.mkIf (cfg.publicSharing.enable && cfg.publicSharing.rateLimit.enable) {
        extraConfig = ''
          limit_req zone=nextcloud_share burst=${toString cfg.publicSharing.rateLimit.burst} nodelay;
          limit_req zone=nextcloud_preview burst=${toString cfg.publicSharing.rateLimit.previewBurst} nodelay;
        '';
      })

      # Sinon `trusted_proxies` fait lire un X-Forwarded-For que Cloudflare complète :
      # l'appelant choisit son IP et remet à zéro l'anti-force-brute.
      {
        locations."~ \\.php(?:$|/)".extraConfig = ''
          fastcgi_param HTTP_X_FORWARDED_FOR $real_client_ip;
        '';
      }

      (lib.mkIf (cfg.publicSharing.enable && cfg.publicSharing.canonicalLinkHost) {
        locations."~ \\.php(?:$|/)".extraConfig = ''
          fastcgi_param HTTP_HOST $nextcloud_link_host;
        '';
      })

      # Location à part : la location PHP sert aussi le WebDAV, dont les 404 sont normaux.
      # Priorité sous celle de la location PHP : nginx retient la première regex correspondante.
      (lib.mkIf (cfg.publicSharing.enable && cfg.publicSharing.neutralNotFound) {
        # Pas de theming : `apps/theming/img/` mêle route PHP et statiques (images cassées).
        locations."~ ^/(?:index\\.php/)?(?:s/|apps/files_sharing/(?:publicpreview|shareinfo))" = {
          priority = phpLocation.priority - 10;
          inherit (phpLocation) fastcgiParams;
          extraConfig =
            phpLocation.extraConfig
            + ''
              error_page 404 = @nextcloud_share_404;
            ''
            # nginx n'hérite les `error_page` que s'il n'y en a aucune : répéter le 401.
            + lib.optionalString authelia.enable ''
              error_page 401 = @authelia_or_app;
            '';
        };

        locations."@nextcloud_share_404".extraConfig = ''
          internal;
          # `auth_request` est hérité.
          auth_request off;
          default_type text/html;

          # `-s 404` obligatoire : sinon le 404 n'est pas dans la liste de codes traitée.
          more_clear_headers -s 404 'Set-Cookie';

          return 404 '${
            myLib.server.mkErrorPage {
              title = "Lien introuvable";
              body = ''
                <p>Ce lien de partage n&rsquo;existe pas, ou il a expir&eacute;.</p>
                <p>Redemande-en un &agrave; la personne qui te l&rsquo;a envoy&eacute;.</p>'';
            }
          }';
        '';
      })

      (lib.mkIf authelia.enable authelia.nginxAuthRequest)

      (lib.mkIf authelia.enable {
        extraConfig = ''
          # Un 302 à Location vide casserait la synchronisation WebDAV.
          error_page 401 = @authelia_or_app;
        '';

        locations."@authelia_or_app".extraConfig = ''
          internal;

          if ($redirection_url != "") {
            return 302 $redirection_url;
          }

          # En-têtes recopiés du module Nextcloud : un `add_header` de location remplace la liste du parent.
          add_header X-Content-Type-Options nosniff always;
          add_header X-Robots-Tag "noindex, nofollow" always;
          add_header X-Permitted-Cross-Domain-Policies none always;
          add_header X-Frame-Options sameorigin always;
          add_header Referrer-Policy no-referrer always;
          add_header Strict-Transport-Security "max-age=${toString config.services.nextcloud.nginx.hstsMaxAge}; includeSubDomains" always;
          return 401;
        '';
      })
    ];
  };
}
