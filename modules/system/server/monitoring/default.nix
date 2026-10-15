{
  config,
  lib,
  ...
}:

# Surveillance du host : métriques, alertes, et une interface pour regarder les
# courbes.
#
# CE QUE ÇA COMPLÈTE, et pourquoi ce n'est pas redondant. `systemSettings.notify.discord`
# signale un ÉVÉNEMENT — une unité qui échoue — et `acme-expiry-check` vérifie
# un ÉTAT précis, celui du certificat servi. Ni l'un ni l'autre ne voit venir
# une panne : un disque à 92 %, une mémoire qui part en swap, une unité qui
# échoue une fois par nuit sans que personne ne relie les occurrences. C'est ce
# trou-là que ce module ferme, et c'est le seul.
#
# LES BRIQUES, chacune avec un rôle qui ne recouvre pas les autres. Les quatre
# premières sont le socle et sont toujours là ; les deux suivantes s'allument par
# option, sur des hosts qui ont quelque chose à leur donner à regarder :
#
#   - node_exporter  : ce que la machine sait d'elle-même (disque, mémoire,
#                      charge, état des unités systemd, dérive d'horloge).
#   - blackbox       : ce qu'un client voit en tapant sur une URL — code de
#                      retour, temps de réponse, expiration du certificat.
#   - Prometheus     : collecte, historique, et ÉVALUATION DES RÈGLES. C'est lui
#                      qui décide qu'il y a un problème.
#   - Alertmanager   : regroupe, dédoublonne, et pousse vers Discord.
#   - `apps`         : ce que les SERVICES savent d'eux-mêmes et que la machine
#                      ignore — un pool PHP saturé, un portail qui refuse tout
#                      le monde. Le processeur va très bien pendant ce temps-là.
#   - `logs`         : Vector lit le journal, Loki le range. Tout le reste ici
#                      mesure des nombres, et un nombre ne dit jamais POURQUOI.
#                      Loki sert aussi de second moteur d'alerte, mais seulement
#                      pour ce qu'aucune métrique ne peut voir.
#
# Grafana n'est PAS dans cette liste, et ce n'est pas un oubli : il ne fait que
# regarder. Rien de ce qui prévient ne dépend de lui, on peut l'arrêter sans
# perdre une alerte.
#
# LA LIMITE, à garder en tête avant de s'y fier : tout ça tourne SUR la machine
# surveillée. Si elle s'arrête, Prometheus s'arrête avec, et le silence qui
# suit ressemble exactement à « tout va bien ». C'est la raison d'être de
# `deadManSwitch`, seule pièce dont la défaillance se voit depuis l'extérieur.
#
# AUCUN PORT OUVERT : chaque composant écoute sur la boucle locale, et le seul
# accès est le vhost Grafana, derrière le tunnel et Authelia comme Nextcloud.
#
# ORGANISATION DU DOSSIER. Ce fichier ne porte que l'interface (options,
# assertions). Le reste :
#
#   - internal.nix   : le contrat entre les fichiers (ports, tâches de collecte,
#                      règles, panneaux déposés par nom) ;
#   - components/    : une tranche par composant observé — son exporteur, sa
#                      tâche de collecte, ses règles et ses panneaux ensemble ;
#   - prometheus.nix, alertmanager.nix, loki.nix, vector.nix, grafana.nix : les
#                      services, qui ramassent ce que les composants déposent ;
#   - dashboard.nix  : le squelette du tableau de bord (sections, bandes) ;
#   - lib/server/grafana.nix (myLib.server.grafana) : les constructeurs de panneaux.
let
  cfg = config.systemSettings.monitoring;
  authelia = config.systemSettings.authelia;
  cloudflared = config.systemSettings.cloudflared;
  nextcloud = config.systemSettings.nextcloud;
  proxy = config.systemSettings.proxy;
in
{
  options.systemSettings.monitoring = {
    enable = lib.mkEnableOption "surveillance du host (Prometheus, Alertmanager, Grafana)";

    retention = lib.mkOption {
      type = lib.types.str;
      default = "90d";
      description = ''
        Durée pendant laquelle Prometheus garde les mesures.

        Quatre-vingt-dix jours et non trente : sur ce volume de séries, la
        différence se compte en centaines de mégaoctets, et c'est précisément la
        fenêtre qui permet de répondre à « est-ce que ça a toujours été comme
        ça ? » — la question qu'on se pose vraiment devant une courbe.
      '';
    };

    scrapeInterval = lib.mkOption {
      type = lib.types.str;
      default = "30s";
      description = ''
        Fréquence de collecte des métriques locales. Les sondes blackbox ont la
        leur, plus lâche : elles ouvrent une vraie connexion TLS.
      '';
    };

    blackbox.targets = lib.mkOption {
      default = { };
      description = ''
        Points sondés DEPUIS l'extérieur des applications, par une vraie requête
        HTTP. Sans cible, l'exporteur blackbox ne tourne pas.

        PIÈGE de cette machine-ci, à connaître avant de choisir une cible : les
        noms publics sont réécrits localement par dnsmasq (cf.
        `systemSettings.dns.overrides`), donc une sonde lancée d'ici tape sur
        nginx en direct et NE TRAVERSE PAS le tunnel Cloudflare. Elle ne dit donc
        rien de la joignabilité depuis internet — seul un tiers peut le dire, et
        c'est encore le rôle de `deadManSwitch`.
      '';
      example = lib.literalExpression ''
        {
          nextcloud = {
            url = "https://cloud.exemple.fr/status.php";
            module = "http_2xx";
          };
        }
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            url = lib.mkOption {
              type = lib.types.str;
              description = "URL complète à sonder, schéma compris.";
            };

            module = lib.mkOption {
              type = lib.types.enum [
                "http_2xx"
                "http_authelia"
              ];
              default = "http_2xx";
              description = ''
                Réponse ATTENDUE de la cible.

                `http_2xx` exige un 2xx : à réserver aux points qui répondent
                vraiment quelque chose, donc à un chemin qui ne passe pas par le
                portail — la sonde vérifie alors l'application elle-même.

                `http_authelia` exige la redirection vers le portail, qui est la
                réponse NORMALE d'un nom protégé sondé depuis le host. Il ne
                prouve que nginx, le certificat et Authelia ; l'application
                derrière peut être à terre sans que ça se voie.
              '';
            };
          };
        }
      );
    };

    disks = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Relève l'état SMART des disques et alerte dessus.

          À PART du reste des métriques parce que c'est la seule chose surveillée
          ici dont la défaillance détruit des DONNÉES au lieu d'interrompre un
          service.

          Ça ne remplace pas `smartd` (cf. modules/system/storage/disks), qui
          surveille en continu et lance des autotests : ça lui donne le canal qui
          lui manque, smartd ne sachant notifier que par une notification de
          bureau sur une machine sans session graphique.

          L'exporteur a besoin de `CAP_SYS_RAWIO` et `CAP_SYS_ADMIN` pour
          interroger les disques, le module amont les lui donne. C'est un
          privilège réel, à mettre en regard de ce qu'il couvre.
        '';
      };

      devices = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "/dev/nvme0n1" ];
        description = ''
          Disques à interroger. Liste VIDE — le défaut — laisse l'exporteur les
          découvrir seul, ce qui est préférable : un disque ajouté est surveillé
          sans qu'on y pense, alors qu'une liste écrite à la main cesse d'être
          juste au premier changement de matériel, sans rien dire.
        '';
      };
    };

    logs = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Collecte le journal de la machine (journald et journaux de nginx) dans
          Loki et l'expose comme source de données de Grafana.

          Tout le reste ici mesure des NOMBRES : une courbe dit qu'une chose a
          mal tourné, à quelle heure et dans quelle proportion — jamais
          POURQUOI. Les deux vues vivent alors dans la MÊME interface, derrière
          le même portail, sur le même axe de temps : on repère le décrochage
          sur la courbe, on lit ce que la machine racontait à cette minute-là.

          DEUX BRIQUES, qui échouent séparément : Vector lit le journal et
          l'envoie (en `DynamicUser`, membre de `systemd-journal`, avec un
          signet dans /var/lib/vector) ; Loki stocke et répond aux requêtes, sur
          la boucle locale comme Prometheus.

          ALERTER RESTE L'AFFAIRE DE PROMETHEUS. Loki ne prend que ce que les
          métriques ne peuvent pas voir, faute d'exister, chaque règle suivant le
          service qu'elle regarde : les rafales d'échecs sur le coffre
          (`vaultwarden.enable`), les rafales de refus SSH (`ssh.enable`), et les
          erreurs de disque du noyau (`kernelAlerts`). Le ruler de Loki n'est
          monté que si l'une d'elles existe.
        '';
      };

      kernelAlerts = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Fait évaluer par Loki une règle sur les erreurs de disque du NOYAU
            (liaison SATA perdue, commande en échec, erreur d'entrée-sortie), et
            la route vers Alertmanager comme les autres.

            VRAI PAR DÉFAUT, contrairement à l'usage de ce dépôt, et pour la
            même raison que `proxy.expiryCheck` : c'est la seule surveillance
            d'une classe de panne que rien d'autre ne voit. Un incident PONCTUEL
            — une liaison qui tombe et revient — ne déplace aucun compteur :
            `DisqueSmartEnEchec` et `DisqueLiaisonSataDegradee` restent muets,
            l'incident n'existe que dans le journal.

            Ne commande QUE cette règle : les règles du coffre et de SSH suivent
            leur propre service.
          '';
        };
      };

      retention = lib.mkOption {
        type = lib.types.str;
        default = "30d";
        description = ''
          Durée pendant laquelle Loki garde les journaux.

          TRENTE JOURS et non quatre-vingt-dix comme `retention` plus haut : une
          métrique répond à « est-ce que ça a toujours été comme ça ? », question
          qui porte sur des mois ; un journal répond à « que s'est-il passé cette
          nuit-là », question qui porte sur des jours.

          Pour que l'augmenter soit une décision informée : mesuré sur cette
          machine le 20 août 2026, 77 000 lignes et 18,5 Mo bruts par jour, dont
          60 % pour le seul agent Datadog (cf. `excludeUnits`). Loki compresse
          largement, donc passer à `"90d"` coûte de l'ordre de quelques centaines
          de mégaoctets.

          N'EFFACE RIEN SEULE : Loki n'applique une rétention que si son
          compacteur tourne avec `retention_enabled`, ce que le module pose
          avec (cf. loki.nix). Sans lui, la valeur serait acceptée sans un mot et
          les journaux s'accumuleraient indéfiniment.
        '';
      };

      excludeUnits = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "prometheus-blackbox-exporter.service" ];
        description = ''
          Unités dont le journal n'est PAS envoyé, par nom d'unité complet.

          Vide par défaut : on collecte tout. Une ligne écartée ici est une ligne
          qui n'existera pas le jour où on la cherchera — y compris le jour où
          c'est l'unité écartée qui va mal.

          DEUX CANDIDATS, mesurés sur cette machine le 20 août 2026, si le volume
          devient un sujet :

            - `datadog-agent.service` : 33 600 lignes et 11 Mo par jour, 60 % du
              volume total à lui seul ;
            - `prometheus-blackbox-exporter.service` : 5 760 lignes par jour,
              toutes identiques et NORMALES — les redirections que la sonde
              `http_authelia` attend et compte comme un succès.

          Un service simplement bavard se traite plutôt à la source, comme
          Grafana passé en `log.level = "warn"`.
        '';
      };
    };

    apps = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Métriques APPLICATIVES : nginx, PHP-FPM, Authelia (et son Redis),
          PostgreSQL, WireGuard, dnsmasq.

          Ce que ça ajoute au reste du module, qui ne regarde que la MACHINE :
          node-exporter dira toujours que le processeur va bien pendant que
          Nextcloud met trente secondes à répondre parce que son pool PHP est
          saturé, et les sondes blackbox diront que le portail répond pendant
          qu'il refuse toutes les authentifications.

          Chaque exporteur n'est activé que si le service qu'il observe l'est :
          rien ne démarre pour surveiller ce qui n'existe pas.

          NE COUVRE PAS Nextcloud lui-même (comptes, fichiers, stockage) : son
          exporteur exige un jeton créé à la main, cf. `apps.nextcloudTokenKey`.
        '';
      };

      nextcloudTokenKey = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "nextcloud/serverinfo_token";
        description = ''
          Clé sops du jeton `serverinfo` de Nextcloud. `null` — le défaut —
          laisse l'exporteur Nextcloud éteint ; il ne tourne de toute façon
          qu'avec `apps.enable` et `systemSettings.nextcloud.enable`.

          DEUX GESTES MANUELS, qui ne peuvent pas être automatisés : le jeton
          est produit par l'instance elle-même.

            nextcloud-occ config:app:set serverinfo token --value "$(openssl rand -hex 32)"
            secrets edit nextcloud/serverinfo_token

          Le jeton donne accès à l'état de l'instance, pas à son contenu — d'où
          ce chemin plutôt que la réutilisation de `nextcloud/admin_pass`, qui
          ferait de l'exporteur un administrateur complet pour afficher trois
          compteurs.
        '';
      };
    };

    grafana = {
      hostName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "metrics.exemple.fr";
        description = ''
          Nom sous lequel Grafana est servi. Il doit être couvert par le domaine
          de session d'Authelia, sinon le cookie du portail ne l'accompagne pas.
        '';
      };

      public = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Publie Grafana par le tunnel, en plus du LAN et du VPN.

          Il n'est jamais servi sans le portail : la protection est posée dès
          qu'Authelia est actif, et une assertion refuse la publication sans lui.
          C'est le point à ne pas relâcher — Grafana en accès libre expose la
          topologie de la machine, ses points de montage et l'état de ses
          services.
        '';
      };
    };

    deadManSwitch = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Envoie un battement de cœur périodique à un service TIERS, qui prévient
          quand il cesse d'arriver.

          C'EST LA SEULE PIÈCE qui couvre la panne dont tout le reste est
          incapable de parler. Prometheus, Alertmanager et Discord tournent tous
          SUR la machine surveillée : si elle s'éteint, si le réseau tombe, si le
          disque passe en lecture seule, le silence qui suit est indiscernable
          d'un fonctionnement normal. Ici c'est l'ABSENCE de signal qui alerte,
          et le juge est ailleurs.

          Le battement porte l'alerte `Watchdog`, toujours en échec par
          construction : il s'interrompt donc aussi quand Prometheus n'évalue
          plus ses règles ou qu'Alertmanager ne route plus. Toute la chaîne est
          prouvée, pas seulement la présence de la machine.

          À régler côté tiers : une période un peu plus longue que
          `deadManSwitch.interval`, avec un délai de grâce — sinon un
          redémarrage de rebuild suffit à déclencher une fausse alerte.
        '';
      };

      pingUrlKey = lib.mkOption {
        type = lib.types.str;
        default = "healthchecks/ping_url";
        description = ''
          Clé sops de l'URL de ping, dans les secrets SYSTÈME.

          C'est une URL-capacité : qui la détient peut envoyer le battement à ta
          place, donc maintenir le service en « tout va bien » alors que la
          machine est morte. Elle n'a rien à faire dans ce dépôt, qui est public.
        '';
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "5m";
        description = "Période entre deux battements.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.grafana.hostName != null;
        message = "systemSettings.monitoring : grafana.hostName est requis, c'est le nom du vhost qui sert l'interface.";
      }
      {
        assertion = authelia.enable;
        message = ''
          systemSettings.monitoring exige systemSettings.authelia.enable.
          Grafana montre la topologie de la machine, ses points de montage et l'état de ses
          services : il n'est servi derrière aucune authentification propre (le formulaire de
          connexion est coupé au profit du portail), donc sans Authelia il serait en accès libre.
        '';
      }
      {
        assertion = proxy.enable;
        message = "systemSettings.monitoring exige systemSettings.proxy.enable (nginx et le certificat du vhost Grafana).";
      }
      {
        assertion = !cfg.grafana.public || cloudflared.enable;
        message = "systemSettings.monitoring.grafana.public exige systemSettings.cloudflared.enable, aucun port n'étant ouvert sur la box.";
      }
      {
        # L'exporteur Nextcloud vise le PREMIER nom supplémentaire, jamais le nom
        # public — sur celui-ci il récolterait la page de connexion du portail.
        # Sans nom supplémentaire, `lib.head` sur une liste vide fait échouer
        # l'évaluation sur « list index 0 is out of bounds », un message qui ne
        # nomme ni l'option en cause ni le module. Autant le dire.
        assertion = cfg.apps.nextcloudTokenKey == null || nextcloud.extraHostNames != [ ];
        message = ''
          systemSettings.monitoring.apps.nextcloudTokenKey exige au moins un systemSettings.nextcloud.extraHostNames.
          L'exporteur interroge l'API serverinfo sous le nom INTERNE, celui que la règle de contournement
          d'Authelia laisse passer : sous le nom public il reçoit la page de connexion du portail et échoue
          sur « invalid character '<' », du HTML là où il attend du JSON.
        '';
      }
    ];

    warnings = lib.optional (!cfg.deadManSwitch.enable) ''
      systemSettings.monitoring : aucun dead man's switch sur ce host.
      Prometheus, Alertmanager et le notifieur Discord tournent tous SUR la machine surveillée :
      si elle s'arrête, plus rien n'est envoyé et le silence ressemble exactement à « tout va bien ».
      Active systemSettings.monitoring.deadManSwitch.
    '';
  };
}
