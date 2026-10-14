{
  config,
  lib,
  myLib,
  ...
}:

# Ce que le journal sait et que les métriques ignorent : les panneaux de la
# section « Journaux », les surfaces d'authentification sans métrique (coffre,
# SSH), et la surveillance de la collecte elle-même. Loki et Vector sont
# configurés dans loki.nix et vector.nix.
#
# LOKI COMME MOTEUR D'ALERTE, seulement pour ce qu'aucune métrique ne peut voir,
# faute d'exister : tout ce qui se mesure se surveille dans Prometheus, et
# dédoubler les règles entre deux moteurs reviendrait à ne plus savoir lequel a
# parlé.
let
  cfg = config.systemSettings.monitoring;
  vaultwarden = config.systemSettings.vaultwarden.enable;
  ssh = config.systemSettings.ssh.enable;
  inherit (myLib.grafana) mkTs mkLogs lokiDs;

  # Sélections LogQL partagées entre la règle et le panneau qui la montre.
  coffreEchecs = ''{unit="vaultwarden.service"} |= "(login)" |= "400 Bad Request"'';
  sshRefus = ''{unit="sshd.service"} |~ "Failed password|Invalid user"'';

  # Lignes que Vector remet à Loki : le PUITS et non la source, c'est le
  # dernier maillon, celui qui prouve que la ligne est vraiment arrivée.
  envoisVersLoki = ''vector_component_sent_events_total{component_id="loki",component_kind="sink"}'';

  # Panneau de décompte tiré du journal.
  #
  # `or vector(0)` SUR CHAQUE SÉRIE, et c'est le cœur de ces panneaux : sans
  # lui, une période sans aucun événement ne rend AUCUNE série, et Grafana
  # affiche « No Data » — qui veut dire aussi bien « personne ne s'est
  # connecté » que « la source est cassée ». Sur un panneau dont l'intérêt est
  # justement d'être vide la plupart du temps, c'est le pire message possible.
  # Le zéro dit « je regarde, et il ne s'est rien passé ».
  #
  # `bars` et non une ligne : on compte des événements par intervalle.
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
            # LA COLLECTE DE JOURNAUX QUI SE CASSE SANS S'ARRÊTER. Vector actif
            # mais qui rejette ce qu'il lit — Loki qui refuse, un puits saturé,
            # une ligne illisible — laisse l'unité `active` et la cible `up`.
            #
            # Compteur ABSENT tant qu'aucune erreur n'est survenue : la règle ne
            # s'évalue sur rien et ne peut donc pas déclencher à tort. Elle prend
            # vie au premier incident.
            CollecteDeJournauxEnErreur = {
              alert = "CollecteDeJournauxEnErreur";
              expr = "increase(vector_component_errors_total[15m]) > 0";
              for = "10m";
              labels.severity = "warning";
              annotations.summary = "Vector rejette des événements ({{ $labels.component_id }}) : les journaux arrivent incomplets sans que rien ne tombe.";
            };

            # LA MÊME PANNE, DANS SA FORME SILENCIEUSE. Un rejet PRODUIT une
            # erreur, donc un compteur. Une collecte qui s'arrête n'en produit
            # aucune : il suffit que Vector perde l'accès au journal (cf. le
            # `mkForce` des `SupplementaryGroups` dans vector.nix) pour que
            # l'unité reste `active`, `up` vaille 1, le compteur d'erreurs reste
            # à zéro, et que Grafana affiche une page qui fonctionne et qui est
            # vide.
            #
            # SIX HEURES : la fenêtre doit dépasser le plus long silence NORMAL de
            # la machine. Il n'y en a pas en pratique — la sonde blackbox remplit
            # l'access.log de nginx chaque minute — mais `excludeUnits` peut faire
            # taire une source. Une panne de collecte n'est pas urgente à la
            # minute ; ce qu'on veut, c'est ne pas la découvrir un mois plus tard.
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
              # Empilé : ce qui intéresse ici est le volume TOTAL et la part
              # d'anormal dedans, pas trois courbes à comparer entre elles.
              stack = true;
              fill = 60;
              decimals = 0;
              targets = [
                {
                  # `$__auto` cale la fenêtre de comptage sur la largeur d'un
                  # pixel du graphique : les barres restent lisibles qu'on regarde
                  # une heure ou une semaine.
                  #
                  # `unit` est la seule étiquette que le transform de
                  # normalisation garantit sur CHAQUE ligne — y compris celles du
                  # noyau —, et Loki exige au moins un sélecteur qui ne
                  # corresponde pas au vide.
                  expr = ''sum by (level) (count_over_time({unit=~"${"$"}{unite:regex}"} |= "${"$"}{contient}"[$__auto]))'';
                  legend = "{{level}}";
                }
              ];
            };

            # PAS le journal entier, à dessein : il est à plus de 99 % fait
            # d'`info`, et tout afficher ici reviendrait à ne rien montrer. Les
            # deux gravités par défaut font une centaine de lignes par jour —
            # une quantité qu'un humain parcourt vraiment. Le reste est dans
            # Explore, à un clic, et la barre du panneau au-dessus le compte.
            journalErreurs = mkLogs {
              id = 32;
              title = "Journal : erreurs et avertissements";
              description = "Filtré par les trois variables du haut du tableau. Le journal complet — dont 99,5 % d'`info` — est dans Explore, à un clic.";
              expr = ''{level=~"${"$"}{gravite:regex}", unit=~"${"$"}{unite:regex}"} |= "${"$"}{contient}"'';
            };

            # LA COLLECTE DE JOURNAUX vue comme un débit : le mode de panne réel
            # est une collecte qui S'ARRÊTE, et la seule façon de le voir est de
            # regarder une courbe. Dans la section Surveillance, à côté des cibles
            # de collecte, où la question « la chaîne fonctionne-t-elle » est
            # posée.
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

      # LE COFFRE-FORT, le service le plus sensible du host et le seul dont
      # Prometheus ne peut RIEN dire : Vaultwarden n'expose aucune métrique (son
      # port local répond 404 sur `/metrics`). Une sonde dit qu'il répond, le
      # signalement d'échec que son unité tient ; aucun des deux ne voit ce qui
      # compte sur un coffre — que quelqu'un essaie d'y entrer.
      (lib.mkIf vaultwarden {
        systemSettings.monitoring.internal.lokiRuleGroups.coffre = {
          name = "coffre";
          interval = "1m";
          rules = [
            {
              # SUR UNE RAFALE, PAS SUR UN ÉCHEC. Se tromper de mot de passe est
              # banal, ce sont des fautes de frappe étalées sur des jours.
              # Alerter à la première apprendrait à ne plus lire. Cinq en un
              # quart d'heure ne ressemble plus à une main humaine qui se trompe.
              #
              # CE QUE ÇA VEUT DIRE ICI, et c'est ce qui rend l'alerte grave : le
              # coffre n'est joignable que depuis les appareils appairés au VPN
              # (cf. `vaultwarden.allowedNetworks`). Une rafale ne peut donc pas
              # venir d'internet — c'est une alerte sur un appareil compromis,
              # pas sur un inconnu qui frappe à la porte.
              alert = "CoffreTentativesRepetees";
              expr = "sum(count_over_time(${coffreEchecs} [15m])) > 5";
              labels.severity = "critical";
              annotations.summary = "{{ $value | printf \"%.0f\" }} échecs de connexion au coffre en 15 min. L'accès étant restreint au VPN, ça vient d'un appareil appairé.";
            }
          ];
        };
      })

      # SSH, dont AUCUNE métrique ne parle : sshd ne publie rien, ses refus
      # d'authentification n'existent que dans le journal, comme ceux du coffre.
      (lib.mkIf ssh {
        systemSettings.monitoring.internal.lokiRuleGroups.acces = {
          name = "acces";
          interval = "1m";
          rules = [
            {
              # DIX EN UN QUART D'HEURE. Le port est décalé (cf.
              # `systemSettings.ssh.port`), ce qui écarte les balayages
              # automatiques qui ne tapent que sur 22 : une campagne qui trouve CE
              # port-là est un événement, pas du bruit de fond. Le seuil reste
              # haut pour absorber une clé mal configurée qui réessaie : ce qu'on
              # veut attraper est l'insistance, pas l'erreur ponctuelle.
              #
              # Motifs relevés dans le journal réel — `Invalid user … from …` et
              # `Failed password` — et requête validée contre Loki.
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
              # LE TROU QUE CETTE RÈGLE FERME, et il est réel : le 19 août 2026, la
              # liaison SATA du disque SYSTÈME est tombée et revenue, une écriture
              # a échoué, et RIEN n'a alerté. Ni `DisqueSmartEnEchec` — le disque
              # est sain —, ni `DisqueLiaisonSataDegradee` — le compteur CRC n'a
              # pas bougé, une perte de lien n'étant pas une erreur de
              # transmission. L'événement n'existait QUE dans le journal du
              # noyau : un incident ponctuel ne déplace aucun compteur.
              #
              # `unit="noyau"` est l'étiquette que le transform de normalisation
              # de Vector pose sur les messages sans unité systemd, le noyau au
              # premier chef.
              alert = "DisqueErreurAtaNoyau";
              expr = ''sum(count_over_time({unit="noyau"} |~ `(?i)(exception Emask|SError:|failed command|hard resetting link|I/O error)`[10m])) > 0'';
              labels.severity = "warning";
              annotations.summary = "Le noyau signale une erreur de liaison ou de commande sur un disque ({{ $value | printf \"%.0f\" }} ligne(s) en 10 min). Câble ou connecteur SATA — vérifie `journalctl -k | grep -i ata`.";
            }
          ];
        };
      })

      # LES DEUX SURFACES D'AUTHENTIFICATION, en panneaux : l'alerte dit qu'un
      # seuil est franchi, elle ne dit pas à quoi ressemblait l'avant. Devant
      # une notification à 3 h du matin, la question est « coup isolé ou montée
      # depuis une heure », et c'est une forme de courbe, pas un nombre.
      #
      # Sous `apps.enable` en plus : ils vivent dans la section « Services »,
      # qui n'existe qu'avec lui.
      (lib.mkIf (cfg.apps.enable && vaultwarden) {
        # PEU DE DONNÉES, ET C'EST NORMAL : quelques connexions par jour sur un
        # coffre familial. Le jour où le panneau n'est plus vide, quelque chose
        # se passe.
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
        # LES DEUX SENS, et le rapport entre eux est l'information : une rafale
        # de refus sur un port décalé veut dire que quelqu'un a trouvé le port et
        # insiste.
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
