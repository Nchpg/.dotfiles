{
  config,
  lib,
  myLib,
  pkgs-stable,
  ...
}:

# WireGuard : le dernier contact de chaque pair du VPN.
let
  cfg = config.systemSettings.monitoring;
  wireguard = config.systemSettings.vpn.wireguard;
  inherit (cfg.internal) ports helpers;
  inherit (myLib.grafana) mkTs;

  # Le nom lisible des pairs WireGuard n'est PAS dans l'interface : `wg show` ne
  # connaît que des clés publiques. L'exporteur sait les traduire, à condition
  # qu'on lui donne un fichier au format wg-quick portant des commentaires
  # `# friendly_name`. Cette machine monte wg0 par systemd-networkd et n'a donc
  # aucun fichier de ce genre — on le fabrique depuis la même liste de pairs qui
  # sert à configurer l'interface, ce qui garantit qu'il ne peut pas diverger.
  #
  # AUCUN SECRET DEDANS, et c'est ce qui permet de le poser dans le store : que
  # des clés PUBLIQUES et des noms. Les clés pré-partagées restent dans sops.
  #
  # LE COMMENTAIRE VA DEDANS, après `[Peer]`, et l'ordre n'est pas une question
  # de style : l'exporteur rattache `# friendly_name` à la section OUVERTE au
  # moment où il le lit. Placé avant `[Peer]`, chaque nom glisse sur le pair
  # suivant et le dernier n'en reçoit aucun.
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
          # Sans ça, chaque pair n'apparaît que par sa clé publique : lisible par
          # une machine, inutilisable dans une alerte qu'un humain doit lire à
          # 5 h.
          wireguardConfig = wireguardNames;
        };

        # Une poignée de pairs, une valeur qui ne bouge qu'à la connexion :
        # collecter plus souvent ne dirait rien de plus.
        systemSettings.monitoring.internal.scrapeJobs.wireguard =
          helpers.localJob "wireguard" ports.wireguardExporter
          // {
            scrape_interval = "1m";
          };
      })

      {
        # Pas d'alerte là-dessus, volontairement : ces pairs sont des téléphones
        # qui se connectent quand ils veulent. Un long silence est normal, et une
        # règle dessus sonnerait chaque nuit.
        systemSettings.monitoring.internal.panels.wireguard = mkTs {
          id = 27;
          title = "WireGuard : dernier contact des pairs";
          unit = "s";
          description = "Ancienneté de la dernière poignée de main, par pair. Un long silence est NORMAL — ce sont des téléphones. Le panneau sert à répondre à « pourquoi mon téléphone ne passe plus », pas à prévenir.";
          targets = [
            {
              # L'exporteur publie l'HORODATAGE de la dernière poignée de main,
              # pas son ancienneté : la soustraction est faite ici.
              #
              # LE `and` N'EST PAS UN FILTRE DE CONFORT : l'horodatage vaut ZÉRO
              # pour un pair qui ne s'est jamais connecté, et la soustraction
              # rend alors l'heure Unix courante, cinquante-six ans. Deux pairs
              # jamais appairés suffisaient à écraser tous les autres contre
              # l'axe. Savoir qu'un pair n'a jamais communiqué se lit dans la
              # liste des pairs du profil, pas sur un graphique d'ancienneté.
              expr = "(time() - wireguard_latest_handshake_seconds) and (wireguard_latest_handshake_seconds > 0)";
              legend = "{{ friendly_name }}";
            }
          ];
        };
      }
    ]
  );
}
