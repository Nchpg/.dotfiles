{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.systemSettings.apps;

  authelia = config.systemSettings.authelia;

  ssoApps = lib.filterAttrs (_: app: app.sso.enable) cfg;

  limitedApps = lib.filter (n: cfg.${n}.rateLimit.enable) (lib.attrNames cfg);

  locationsOf =
    app:
    let
      timeout = lib.optionalString (app.proxyTimeout != null) ''
        proxy_read_timeout ${app.proxyTimeout};
        proxy_send_timeout ${app.proxyTimeout};
      '';

      target = {
        proxyPass = "http://127.0.0.1:${toString app.hostPortEffective}";
        proxyWebsockets = true;
      }
      // lib.optionalAttrs (timeout != "") { extraConfig = timeout; };

      limit = timeout + ''
        limit_req zone=${app.zone} burst=${toString app.rateLimit.burst} nodelay;
      '';

      limitedPaths = lib.optionals app.rateLimit.enable app.rateLimit.paths;
    in
    {
      "/" =
        target
        // lib.optionalAttrs (app.rateLimit.enable && app.rateLimit.paths == [ ]) {
          extraConfig = limit;
        };
    }
    // lib.listToAttrs (
      map (path: lib.nameValuePair path (target // { extraConfig = limit; })) limitedPaths
    );
in
{
  config = lib.mkIf (cfg != { }) {
    # `mkAfter` : nginx refuse une variable pas encore vue, il faut suivre le `map` de `$real_client_ip`.
    services.nginx.commonHttpConfig = lib.mkIf (limitedApps != [ ]) (
      lib.mkAfter (
        lib.concatMapStrings (
          n: "limit_req_zone $real_client_ip zone=${cfg.${n}.zone}:10m rate=${cfg.${n}.rateLimit.rate};\n"
        ) limitedApps
      )
    );

    # Les locations n'ont pas d'`auth_request_set` : elles héritent de celles posées par `nginxProtect`.
    # Liste d'appareils et portail se cumulent : le filtrage d'adresse passe avant le portail.
    services.nginx.virtualHosts = lib.mapAttrs' (
      _: app:
      lib.nameValuePair app.domain (
        myLib.server.mkTlsVhost {
          locations = locationsOf app // lib.optionalAttrs app.sso.enable authelia.nginxProtect.locations;
          extraConfig =
            lib.optionalString (app.allowedNetworks != null) ''
              ${myLib.server.nginxAllowOnly app.allowedNetworks}
            ''
            + lib.optionalString app.sso.enable authelia.nginxProtect.extraConfig;
        }
      )
    ) cfg;

    # Authelia refuse par défaut : sans règle, le portail renverrait 403 à tout le monde.
    systemSettings.authelia.rules = lib.mapAttrsToList (
      _: app:
      {
        inherit (app) domain;
        inherit (app.sso) policy;
      }
      // lib.optionalAttrs (app.sso.subject != null) { inherit (app.sso) subject; }
    ) ssoApps;

    # Pas de `lanShortcut` : la sonde doit traverser l'edge et le tunnel.
    systemSettings.proxy.sites = lib.mapAttrs' (
      name: app:
      lib.nameValuePair app.domain {
        public = app.expose != "vpn";
        lanShortcut = lib.mkDefault false;
        probes = lib.optionalAttrs (app.probe != null) {
          ${name} = {
            inherit (app.probe) path;
            module =
              if app.probe.module != null then
                app.probe.module
              else if app.sso.enable then
                "http_authelia"
              else
                "http_2xx";
          };
        };
      }
    ) cfg;
  };
}
