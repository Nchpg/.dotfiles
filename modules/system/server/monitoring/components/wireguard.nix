{
  config,
  lib,
  myLib,
  pkgs-stable,
  ...
}:

let
  cfg = config.systemSettings.monitoring;
  wireguard = config.systemSettings.vpn.wireguard;
  inherit (cfg.internal) ports helpers;
  inherit (myLib.server.grafana) mkTs;

  # wg0 est monté par systemd-networkd, d'où ce faux wg-quick. Le `# friendly_name` doit suivre `[Peer]`.
  wireguardNames = pkgs-stable.writeText "wg0-peer-names.conf" (
    lib.concatMapStrings (p: ''
      [Peer]
      # friendly_name = ${p.name}
      PublicKey = ${p.publicKey}
      AllowedIPs = ${p.address}/32

    '') wireguard.peers
  );
in
{
  config = lib.mkIf (cfg.enable && cfg.apps.enable) (
    lib.mkMerge [
      (lib.mkIf wireguard.enable {
        services.prometheus.exporters.wireguard = helpers.mkLocalExporter ports.wireguardExporter // {
          wireguardConfig = wireguardNames;
          # IP publique d'où chaque appareil se connecte (étiquette remote_ip) : page VPN du dashboard.
          withRemoteIp = true;
        };

        systemSettings.monitoring.internal.scrapeJobs.wireguard =
          helpers.localJob "wireguard" ports.wireguardExporter
          // {
            scrape_interval = "1m";
          };
      })

      {
        systemSettings.monitoring.internal.panels.wireguard = mkTs {
          id = 27;
          title = "WireGuard : dernier contact des pairs";
          unit = "s";
          description = "Ancienneté de la dernière poignée de main, par pair. Un long silence est NORMAL — ce sont des téléphones. Le panneau sert à répondre à « pourquoi mon téléphone ne passe plus », pas à prévenir.";
          targets = [
            {
              # Le `and` écarte les pairs jamais connectés (horodatage 0).
              expr = "(time() - wireguard_latest_handshake_seconds) and (wireguard_latest_handshake_seconds > 0)";
              legend = "{{ friendly_name }}";
            }
          ];
        };
      }
    ]
  );
}
