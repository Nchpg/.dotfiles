{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.systemSettings.monitoring;
  cloudflared = config.systemSettings.cloudflared;
  inherit (myLib.server.grafana) mkTs;
in
{
  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (lib.mkIf cloudflared.enable {
        systemSettings.cloudflared.metricsAddress = lib.mkDefault "127.0.0.1:2000";
      })

      (lib.mkIf (cloudflared.metricsAddress != null) {
        systemSettings.monitoring.internal = {
          scrapeJobs.cloudflared = {
            job_name = "cloudflared";
            static_configs = [ { targets = [ cloudflared.metricsAddress ]; } ];
          };

          alertRules = {
            # `cloudflared_tunnel_ha_connections` vaut 4 en fonctionnement normal.
            TunnelCloudflareCoupe = {
              alert = "TunnelCloudflareCoupe";
              expr = "cloudflared_tunnel_ha_connections == 0";
              for = "5m";
              labels.severity = "critical";
              annotations.summary = "Le tunnel Cloudflare n'a plus aucune connexion vers l'edge : tout ce qui est publié sur internet est injoignable, alors que le démon tourne.";
              inhibits = {
                alertname = "TunnelCloudflareDegrade";
                equal = [ "instance" ];
              };
            };

            TunnelCloudflareDegrade = {
              alert = "TunnelCloudflareDegrade";
              expr = "cloudflared_tunnel_ha_connections < 4";
              for = "1h";
              labels.severity = "warning";
              annotations.summary = "Le tunnel Cloudflare n'a plus que {{ $value | printf \"%.0f\" }} connexions sur 4 : le service passe encore, la redondance non.";
            };
          };

          panels.tunnelCloudflare = mkTs {
            id = 37;
            title = "Tunnel Cloudflare : connexions vers l'edge";
            unit = "short";
            description = "cloudflared maintient quatre connexions sortantes. En perdre une n'interrompt rien mais annonce souvent la suite ; zéro veut dire que tout ce qui est publié sur internet est injoignable, alors que le démon tourne et que son unité reste active.";
            h = 6;
            decimals = 0;
            targets = [
              {
                expr = "cloudflared_tunnel_ha_connections";
                legend = "connexions";
              }
            ];
          };
        };
      })
    ]
  );
}
