{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.systemSettings.monitoring;
  vaultwarden = config.systemSettings.vaultwarden.enable;
  ssh = config.systemSettings.ssh.enable;
  inherit (myLib.server.grafana) mkTs mkLogs lokiDs;

  coffreEchecs = ''{unit="vaultwarden.service"} |= "(login)" |= "400 Bad Request"'';
  sshRefus = ''{unit="sshd.service"} |~ "Failed password|Invalid user"'';

  envoisVersLoki = ''vector_component_sent_events_total{component_id="loki",component_kind="sink"}'';

  # `or vector(0)` sur chaque série : sinon une période sans événement affiche « No Data ».
  mkDecompte =
    args:
    mkTs (
      {
        unit = "short";
        h = 6;
        ds = lokiDs;
        queryType = "range";
        drawStyle = "bars";
        decimals = 0;
      }
      // args
    );
in
{
  config = lib.mkIf (cfg.enable && cfg.logs.enable) (
    lib.mkMerge [
      {
        systemSettings.monitoring.internal = {
          alertRules = {
            CollecteDeJournauxEnErreur = {
              alert = "CollecteDeJournauxEnErreur";
              expr = "increase(vector_component_errors_total[15m]) > 0";
              for = "10m";
              labels.severity = "warning";
              annotations.summary = "Vector rejette des événements ({{ $labels.component_id }}) : les journaux arrivent incomplets sans que rien ne tombe.";
            };

            # Six heures : au-delà du plus long silence normal (`excludeUnits` peut taire une source).
            CollecteDeJournauxArretee = {
              alert = "CollecteDeJournauxArretee";
              expr = "increase(${envoisVersLoki}[6h]) == 0";
              for = "30m";
              labels.severity = "warning";
              annotations.summary = "Vector n'a expédié aucune ligne vers Loki depuis six heures : la page des journaux reste fonctionnelle et vide, ce qui ressemble à une machine calme.";
            };
          };

          panels = {
            journalParGravite = mkTs {
              id = 31;
              title = "Journal : lignes par gravité";
              description = "Suit les filtres « unité » et « contient » du haut du tableau, mais PAS celui de gravité : ce panneau EST la répartition par gravité, la filtrer masquerait les barres qu'on vient regarder.";
              h = 6;
              ds = lokiDs;
              queryType = "range";
              drawStyle = "bars";
              stack = true;
              fill = 60;
              decimals = 0;
              targets = [
                {
                  # `unit` est la seule étiquette garantie sur chaque ligne ; Loki exige un sélecteur non vide.
                  expr = ''sum by (level) (count_over_time({unit=~"${"$"}{unite:regex}"} |= "${"$"}{contient}"[$__auto]))'';
                  legend = "{{level}}";
                }
              ];
            };

            journalErreurs = mkLogs {
              id = 32;
              title = "Journal : erreurs et avertissements";
              description = "Filtré par les trois variables du haut du tableau. Le journal complet — dont 99,5 % d'`info` — est dans Explore, à un clic.";
              expr = ''{level=~"${"$"}{gravite:regex}", unit=~"${"$"}{unite:regex}"} |= "${"$"}{contient}"'';
            };

            journauxExpedies = mkTs {
              id = 41;
              title = "Journaux expédiés vers Loki";
              unit = "short";
              description = "Lignes que Vector remet à Loki, par minute. C'est le dernier maillon : il prouve que la ligne est vraiment arrivée. Une chute à zéro qui dure est ce que l'alerte `CollecteDeJournauxArretee` attrape au bout de six heures.";
              decimals = 0;
              h = 6;
              targets = [
                {
                  expr = "sum(rate(${envoisVersLoki}[5m])) * 60";
                  legend = "lignes/min";
                }
              ];
            };
          };
        };
      }

      (lib.mkIf vaultwarden {
        systemSettings.monitoring.internal.lokiRuleGroups.coffre = {
          name = "coffre";
          interval = "1m";
          rules = [
            {
              alert = "CoffreTentativesRepetees";
              expr = "sum(count_over_time(${coffreEchecs} [15m])) > 5";
              labels.severity = "critical";
              annotations.summary = "{{ $value | printf \"%.0f\" }} échecs de connexion au coffre en 15 min. L'accès étant restreint au VPN, ça vient d'un appareil appairé.";
            }
          ];
        };
      })

      (lib.mkIf ssh {
        systemSettings.monitoring.internal.lokiRuleGroups.acces = {
          name = "acces";
          interval = "1m";
          rules = [
            {
              # Seuil haut pour absorber une clé mal configurée qui réessaie.
              alert = "SshTentativesRepetees";
              expr = "sum(count_over_time(${sshRefus} [15m])) > 10";
              labels.severity = "critical";
              annotations.summary = "{{ $value | printf \"%.0f\" }} refus d'authentification SSH en 15 min sur un port non standard : quelqu'un a trouvé le port et insiste.";
            }
          ];
        };
      })

      (lib.mkIf cfg.logs.kernelAlerts.enable {
        systemSettings.monitoring.internal.lokiRuleGroups.noyau = {
          name = "noyau";
          interval = "1m";
          rules = [
            {
              # `unit="noyau"` est posé par Vector sur les messages sans unité systemd.
              alert = "DisqueErreurAtaNoyau";
              expr = ''sum(count_over_time({unit="noyau"} |~ `(?i)(exception Emask|SError:|failed command|hard resetting link|I/O error)`[10m])) > 0'';
              labels.severity = "warning";
              annotations.summary = "Le noyau signale une erreur de liaison ou de commande sur un disque ({{ $value | printf \"%.0f\" }} ligne(s) en 10 min). Câble ou connecteur SATA — vérifie `journalctl -k | grep -i ata`.";
            }
          ];
        };
      })

      (lib.mkIf (cfg.apps.enable && vaultwarden) {
        systemSettings.monitoring.internal.panels.coffre = mkDecompte {
          id = 35;
          title = "Coffre : connexions";
          description = "Compté dans le JOURNAL : Vaultwarden n'expose aucune métrique. Vide est l'état normal — quelques connexions par jour. Une rafale d'échecs vient forcément d'un appareil appairé au VPN.";
          targets = [
            {
              expr = ''sum(count_over_time({unit="vaultwarden.service"} |= "(login)" |= "200 OK" [$__auto])) or vector(0)'';
              legend = "réussies";
            }
            {
              expr = "sum(count_over_time(${coffreEchecs} [$__auto])) or vector(0)";
              legend = "échouées";
            }
          ];
        };
      })

      (lib.mkIf (cfg.apps.enable && ssh) {
        systemSettings.monitoring.internal.panels.ssh = mkDecompte {
          id = 43;
          title = "SSH : authentifications";
          description = "sshd n'expose aucune métrique : ces barres sont comptées dans le journal. La ligne de base est de deux ou trois connexions par jour. Le port étant décalé, une rafale de refus n'est pas un balayage automatique.";
          targets = [
            {
              expr = ''sum(count_over_time({unit="sshd.service"} |~ "Accepted (publickey|password)" [$__auto])) or vector(0)'';
              legend = "acceptées";
            }
            {
              expr = "sum(count_over_time(${sshRefus} [$__auto])) or vector(0)";
              legend = "refusées";
            }
          ];
        };
      })
    ]
  );
}
