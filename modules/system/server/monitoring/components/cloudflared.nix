{
  config,
  lib,
  myLib,
  ...
}:

# Le tunnel Cloudflare, vu par sa page de métriques : le SEUL moyen de voir
# l'état du tunnel (cf. la documentation de
# `systemSettings.cloudflared.metricsAddress`).
let
  cfg = config.systemSettings.monitoring;
  cloudflared = config.systemSettings.cloudflared;
  inherit (myLib.server.grafana) mkTs;
in
{
  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # DEMANDE au module du tunnel d'ouvrir sa page de métriques, au lieu
      # d'aller modifier son unité systemd de l'extérieur. C'est lui qui connaît
      # le nom de cette unité, construit à partir de l'UUID par le module amont.
      #
      # `mkDefault` : la valeur reste écrasable depuis un profil, et surtout un
      # `metricsAddress` déjà posé ailleurs n'entre pas en conflit avec celle-ci.
      (lib.mkIf cloudflared.enable {
        systemSettings.cloudflared.metricsAddress = lib.mkDefault "127.0.0.1:2000";
      })

      (lib.mkIf (cloudflared.metricsAddress != null) {
        systemSettings.monitoring.internal = {
          # `up == 0` sur cette tâche attrape le démon qui ne répond plus, et
          # `TunnelCloudflareCoupe` attrape ce qu'il ne voit pas : le démon qui
          # tourne parfaitement sans plus aucun chemin vers l'edge.
          scrapeJobs.cloudflared = {
            job_name = "cloudflared";
            static_configs = [ { targets = [ cloudflared.metricsAddress ]; } ];
          };

          alertRules = {
            # LA PANNE QUE `up` NE VOIT PAS : l'unité systemd reste `active`, le
            # démon tourne, il n'a simplement plus de chemin vers internet. Sa
            # page de métriques répond donc parfaitement pendant que le site est
            # injoignable depuis l'extérieur.
            #
            # Les sondes blackbox ne le voient pas non plus pour la plupart :
            # elles visent des noms que dnsmasq réécrit vers le LAN, donc elles
            # tapent sur nginx sans traverser le tunnel.
            #
            # Nom de métrique RELEVÉ sur la page /metrics du démon et non deviné,
            # les noms de cloudflared s'assemblant à l'exécution :
            # `cloudflared_tunnel_ha_connections`, qui vaut 4 en fonctionnement
            # normal.
            TunnelCloudflareCoupe = {
              alert = "TunnelCloudflareCoupe";
              expr = "cloudflared_tunnel_ha_connections == 0";
              for = "5m";
              labels.severity = "critical";
              annotations.summary = "Le tunnel Cloudflare n'a plus aucune connexion vers l'edge : tout ce qui est publié sur internet est injoignable, alors que le démon tourne.";
              # Zéro connexion est aussi « moins de quatre ».
              inhibits = {
                alertname = "TunnelCloudflareDegrade";
                equal = [ "instance" ];
              };
            };

            # REDONDANCE ENTAMÉE, pas encore de panne : en perdre une des quatre
            # connexions n'interrompt rien, mais annonce souvent la suite.
            #
            # Une heure de `for`, parce qu'une reconnexion ponctuelle fait
            # descendre le compte quelques secondes et n'a rien d'anormal. Ce
            # qu'on veut attraper est l'état qui DURE.
            TunnelCloudflareDegrade = {
              alert = "TunnelCloudflareDegrade";
              expr = "cloudflared_tunnel_ha_connections < 4";
              for = "1h";
              labels.severity = "warning";
              annotations.summary = "Le tunnel Cloudflare n'a plus que {{ $value | printf \"%.0f\" }} connexions sur 4 : le service passe encore, la redondance non.";
            };
          };

          # La question qui suit une notification à 3 h du matin est toujours la
          # même — décrochage isolé ou dégradation qui dure depuis une heure —,
          # et c'est une forme de courbe, pas un nombre.
          #
          # Dans « Accès public » et non dans « Services » : c'est de cela qu'il
          # s'agit, et le tunnel existe indépendamment des exporteurs
          # applicatifs.
          panels.tunnelCloudflare = mkTs {
            id = 37;
            title = "Tunnel Cloudflare : connexions vers l'edge";
            unit = "short";
            description = "cloudflared maintient quatre connexions sortantes. En perdre une n'interrompt rien mais annonce souvent la suite ; zéro veut dire que tout ce qui est publié sur internet est injoignable, alors que le démon tourne et que son unité reste active.";
            # PLUS BAS QUE LES AUTRES : une seule série qui vaut 4 en permanence,
            # rien à démêler, seulement une marche à voir quand elle tombe.
            h = 6;
            decimals = 0;
            # `min = 0` — le défaut — est ici ce qui rend le panneau lisible.
            # Sans borne basse, Grafana cadre sur l'amplitude réelle d'une valeur
            # constante à 4 et dessine une ligne qui semble osciller entre 3,99
            # et 4,01.
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
