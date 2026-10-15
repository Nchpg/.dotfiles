{
  config,
  lib,
  myLib,
  ...
}:

# Ce que nginx sert pour chaque application, et sa publication : vhost avec
# certificat, limitation de débit, route dans le tunnel et sonde.
let
  cfg = config.systemSettings.apps;

  limitedApps = lib.filter (n: cfg.${n}.rateLimit.enable) (lib.attrNames cfg);

  # Locations du vhost. Tout part au point d'entrée : l'aiguillage interne reste
  # l'affaire de l'application, exactement comme sous compose. Les chemins
  # limités sont des locations SUPPLÉMENTAIRES vers la même destination, dont le
  # seul apport est le compteur.
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
      # Liste de chemins VIDE avec la limitation active : c'est toute
      # l'application qui est comptée, y compris ses fichiers statiques.
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
    # ZONES DE LIMITATION, déclarées au niveau `http` — nginx n'en accepte pas
    # ailleurs.
    #
    # La clé est `$real_client_ip` et NON `$binary_remote_addr`, et c'est la
    # décision qui fait tout ici. Le trafic public arrive par cloudflared, donc
    # depuis 127.0.0.1 : compter par adresse de connexion mettrait TOUS les
    # visiteurs venus d'internet dans le même seau. Un seul abus les ferait tous
    # refuser, et l'abuseur ne serait pas isolé une seconde. La variable vient
    # des `map` de modules/system/server/proxy, qui la dérivent de
    # `CF-Connecting-IP` — un en-tête que l'edge de Cloudflare RÉÉCRIT, donc non
    # falsifiable par l'appelant.
    #
    # `mkAfter` n'est PAS cosmétique : nginx compile la clé d'une zone au moment
    # où il lit la directive, et refuse de démarrer sur une variable qu'il n'a
    # pas encore vue. Ces lignes doivent donc passer APRÈS le `map` qui définit
    # `$real_client_ip`.
    #
    # `limit_req_status` n'est plus posé ici : modules/system/server/proxy
    # l'écrit une fois pour tous les vhosts.
    services.nginx.commonHttpConfig = lib.mkIf (limitedApps != [ ]) (
      lib.mkAfter (
        lib.concatMapStrings (
          n: "limit_req_zone $real_client_ip zone=${cfg.${n}.zone}:10m rate=${cfg.${n}.rateLimit.rate};\n"
        ) limitedApps
      )
    );

    services.nginx.virtualHosts = lib.mapAttrs' (
      _: app:
      lib.nameValuePair app.domain (
        myLib.server.mkTlsVhost (
          {
            locations = locationsOf app;
          }
          // lib.optionalAttrs (app.allowedNetworks != null) {
            extraConfig = ''
              ${myLib.server.nginxAllowOnly app.allowedNetworks}
            '';
          }
        )
      )
    ) cfg;

    # Publication de chaque application : une route dans le tunnel déjà existant
    # si elle est publique, et sa sonde quand elle en déclare une.
    #
    # PAS de raccourci dnsmasq vers le LAN (`lanShortcut`), même publique : la
    # sonde d'une application doit sortir jusqu'à l'edge Cloudflare et
    # redescendre par le tunnel, exactement comme un visiteur, pour vérifier le
    # chemin public complet et pas seulement nginx. `mkDefault`, pour qu'un
    # profil puisse le réclamer nom par nom.
    systemSettings.proxy.sites = lib.mapAttrs' (
      name: app:
      lib.nameValuePair app.domain {
        inherit (app) public;
        lanShortcut = lib.mkDefault false;
        probes = lib.optionalAttrs (app.probe != null) { ${name} = app.probe; };
      }
    ) cfg;
  };
}
