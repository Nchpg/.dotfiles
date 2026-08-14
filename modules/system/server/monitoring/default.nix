{
  config,
  lib,
  myLib,
  pkgs-stable,
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
# QUATRE BRIQUES, chacune avec un rôle qui ne recouvre pas les autres :
#
#   - node_exporter  : ce que la machine sait d'elle-même (disque, mémoire,
#                      charge, état des unités systemd, dérive d'horloge).
#   - blackbox       : ce qu'un client voit en tapant sur une URL — code de
#                      retour, temps de réponse, expiration du certificat.
#   - Prometheus     : collecte, historique, et ÉVALUATION DES RÈGLES. C'est lui
#                      qui décide qu'il y a un problème.
#   - Alertmanager   : regroupe, dédoublonne, et pousse vers Discord.
#
# Grafana n'est PAS dans cette liste, et ce n'est pas un oubli : il ne fait que
# regarder. Rien de ce qui prévient ne dépend de lui, on peut l'arrêter sans
# perdre une alerte.
#
# LA LIMITE, à garder en tête avant de s'y fier : tout ça tourne SUR la machine
# surveillée. Si think s'arrête, Prometheus s'arrête avec, et le silence qui
# suit ressemble exactement à « tout va bien ». C'est la raison d'être de
# `deadManSwitch` plus bas, seule pièce dont la défaillance se voit depuis
# l'extérieur.
#
# AUCUN PORT OUVERT : chaque composant écoute sur la boucle locale, et le seul
# accès est le vhost Grafana, derrière le tunnel et Authelia comme Nextcloud.
let
  cfg = config.systemSettings.monitoring;
  authelia = config.systemSettings.authelia;
  cloudflared = config.systemSettings.cloudflared;
  notify = config.systemSettings.notify.discord;

  # Ports de BOUCLAGE, détails d'implémentation : rien ici n'est joignable de
  # l'extérieur, donc aucune de ces valeurs n'est une adresse à communiquer.
  # Constantes plutôt qu'options, contrairement à `authelia.port` : aucun autre
  # module n'a de raison de les reprendre.
  ports = {
    prometheus = 9090;
    alertmanager = 9093;
    node = 9100;
    blackbox = 9115;
    grafana = 3000;
    smartctl = 9633;
  };

  # Répertoire où systemd dépose les credentials de l'unité alertmanager.
  #
  # Écrit en dur parce qu'il le faut : le fichier de configuration vit dans le
  # store et ne peut pas contenir `%d`, qui n'est développé que dans les
  # directives d'unité. Le chemin est celui que systemd garantit et expose par
  # $CREDENTIALS_DIRECTORY (systemd.exec) — c'est déjà l'hypothèse que fait le
  # notifieur de modules/system/notify.
  #
  # POURQUOI PASSER PAR LÀ plutôt que lire /run/secrets directement : le module
  # amont fait tourner alertmanager en `DynamicUser`, donc sous un uid qui
  # change à chaque démarrage. Aucun `owner` sops ne peut désigner ce compte.
  # systemd, lui, lit le secret en root AVANT d'abaisser les privilèges et le
  # remet en lecture seule pour cette unité-là seulement.
  amCredentials = "/run/credentials/alertmanager.service";

  # Filtre commun aux règles sur les systèmes de fichiers.
  #
  # `/nix/store` en est EXCLU, et ça n'a rien d'esthétique : sur NixOS c'est un
  # montage lié en lecture seule de la racine, donc node_exporter le rapporte
  # comme un système de fichiers à part alors qu'il partage les mêmes octets.
  # Sans cette exclusion, chaque alerte de remplissage partirait en double, sur
  # deux points de montage qui désignent le même disque.
  #
  # `/boot` est gardé À DESSEIN, alors qu'on l'oublie souvent : c'est la
  # partition qui se remplit toute seule sur cette distribution, une génération
  # à la fois, et son remplissage casse le rebuild suivant.
  fsSelector = ''fstype!~"tmpfs|ramfs|overlay|nsfs|squashfs|fuse.*",mountpoint!="/nix/store"'';

  # SOCLE COMMUN des sondes HTTP. Les deux modules ne diffèrent que par le code
  # de retour attendu ; tout le reste — la version du protocole, le refus de
  # suivre les redirections, l'exigence de TLS, la famille d'adresses — porte une
  # décision qui doit valoir pour TOUTES les sondes.
  #
  # Écrit une fois plutôt que recopié : deux blocs jumeaux finissent toujours par
  # diverger sur la ligne qu'on a oublié de reporter, et la divergence ne se voit
  # pas — la sonde continue de répondre, simplement elle ne vérifie plus la même
  # chose.
  mkHttpProber = valid_status_codes: {
    prober = "http";
    timeout = "10s";
    http = {
      method = "GET";
      valid_http_versions = [
        "HTTP/1.1"
        "HTTP/2.0"
      ];
      inherit valid_status_codes;

      # NE PAS SUIVRE les redirections, alors que blackbox le fait par défaut.
      # Les suivre menait tout droit à la page de connexion du portail, qui
      # répond 200 : la sonde de `cloud.` validait donc Authelia à la place du
      # service qu'elle était censée surveiller, et serait restée verte avec
      # Nextcloud à terre. Sans ce réglage, une sonde ne dit plus « ce service
      # répond » mais « quelque chose répond au bout de la chaîne ».
      follow_redirects = false;

      fail_if_not_ssl = true;

      # Pas d'IPv6 sur ce parc (les annonces de routeur sont refusées, cf.
      # modules/system/network) : sans ce réglage la sonde tente d'abord une
      # famille qui ne répond pas et compte l'échec.
      preferred_ip_protocol = "ip4";
      ip_protocol_fallback = false;
    };
  };

  blackboxConfig = pkgs-stable.writeText "blackbox.yml" (
    builtins.toJSON {
      modules = {
        # Le service répond vraiment. Liste VIDE = le défaut de blackbox, soit
        # 2xx et rien d'autre.
        http_2xx = mkHttpProber [ ];

        # Nom protégé par Authelia, sondé DEPUIS le host. L'adresse source n'est
        # ni celle du VPN ni rien qu'une règle `bypass` reconnaisse, donc le
        # portail répond 302 vers la page de connexion.
        #
        # LE 302 ET RIEN D'AUTRE, et c'est ce qui rend cette sonde utile dans les
        # DEUX SENS. Un 200 sur un nom protégé ne serait pas une bonne nouvelle :
        # il voudrait dire que le portail ne s'interpose plus. L'accepter, c'est
        # écrire une sonde qui reste verte pendant que la protection tombe.
        http_authelia = mkHttpProber [ 302 ];
      };
    }
  );

  probes = lib.attrValues cfg.blackbox.targets;
  probeModules = lib.unique (map (p: p.module) probes);
  urlsFor = m: map (p: p.url) (lib.filter (p: p.module == m) probes);

  # Une tâche de collecte par module blackbox employé : le module est un
  # PARAMÈTRE de requête, il ne peut donc pas varier à l'intérieur d'une tâche.
  #
  # Les `relabel_configs` sont la mécanique standard et non négociable de cet
  # exporteur : l'adresse de la cible doit devenir le paramètre `target`, puis
  # l'adresse réellement contactée doit être remplacée par celle de l'exporteur.
  # Sans la troisième règle, Prometheus irait interroger l'URL surveillée
  # elle-même en lui demandant des métriques.
  blackboxJobs = map (m: {
    job_name = "blackbox-${m}";
    metrics_path = "/probe";
    params.module = [ m ];
    # Moins souvent que le reste : une sonde ouvre une vraie connexion TLS vers
    # un service tiers, on ne le fait pas toutes les trente secondes.
    scrape_interval = "1m";
    scrape_timeout = "15s";
    static_configs = [ { targets = urlsFor m; } ];
    relabel_configs = [
      {
        source_labels = [ "__address__" ];
        target_label = "__param_target";
      }
      {
        source_labels = [ "__param_target" ];
        target_label = "instance";
      }
      {
        target_label = "__address__";
        replacement = "127.0.0.1:${toString ports.blackbox}";
      }
    ];
  }) probeModules;

  # RÈGLES D'ALERTE. C'est la seule partie de ce module qui décide de quelque
  # chose : Prometheus fraîchement installé collecte en silence et ne dit jamais
  # rien tant que rien n'est écrit ici.
  #
  # Deux réglages portent tout le poids et méritent qu'on y revienne quand une
  # alerte agace : le SEUIL, et surtout le `for`, qui exige que la condition
  # tienne pendant toute la durée. C'est lui qui fait la différence entre une
  # alerte qu'on lit et une alerte qu'on apprend à ignorer.
  alertRules = {
    groups = [
      {
        name = "host";
        rules = [
          {
            alert = "CibleInjoignable";
            expr = "up == 0";
            for = "5m";
            labels.severity = "critical";
            annotations.summary = "La cible {{ $labels.instance }} (tâche {{ $labels.job }}) ne répond plus depuis 5 minutes.";
          }
          {
            alert = "DisqueBientotPlein";
            expr = "100 * (1 - node_filesystem_avail_bytes{${fsSelector}} / node_filesystem_size_bytes{${fsSelector}}) > 85";
            for = "30m";
            labels.severity = "warning";
            annotations.summary = "{{ $labels.mountpoint }} occupé à {{ $value | printf \"%.1f\" }} %.";
          }
          {
            alert = "DisquePresquePlein";
            expr = "100 * (1 - node_filesystem_avail_bytes{${fsSelector}} / node_filesystem_size_bytes{${fsSelector}}) > 95";
            for = "5m";
            labels.severity = "critical";
            annotations.summary = "{{ $labels.mountpoint }} occupé à {{ $value | printf \"%.1f\" }} %, la machine va commencer à casser.";
          }
          {
            # La SEULE règle qui prévient AVANT que le seuil soit atteint :
            # elle extrapole la pente des six dernières heures. Le second terme
            # n'est pas décoratif — sans lui, un disque à 4 % d'occupation qui
            # gagne un mégaoctet déclencherait l'alerte au moindre bruit de
            # mesure.
            alert = "DisquePleinEnTroisJours";
            expr = "predict_linear(node_filesystem_avail_bytes{${fsSelector}}[6h], 3 * 24 * 3600) < 0 and node_filesystem_avail_bytes{${fsSelector}} / node_filesystem_size_bytes{${fsSelector}} < 0.4";
            for = "1h";
            labels.severity = "warning";
            annotations.summary = "Au rythme actuel, {{ $labels.mountpoint }} sera plein d'ici trois jours.";
          }
          {
            # Se remplit indépendamment de l'espace, et le message d'erreur qui
            # en découle (« No space left on device » sur un disque à moitié
            # vide) est parmi les plus déroutants qui soient.
            alert = "InodesEpuises";
            expr = "node_filesystem_files_free{${fsSelector}} / node_filesystem_files{${fsSelector}} * 100 < 10";
            for = "30m";
            labels.severity = "warning";
            annotations.summary = "{{ $labels.mountpoint }} : plus que {{ $value | printf \"%.1f\" }} % d'inodes libres.";
          }
          {
            # Bascule que le noyau opère seul quand il trouve une corruption. La
            # machine continue de tourner et de répondre, mais plus rien ne
            # s'écrit — c'est la panne la plus silencieuse de la liste.
            alert = "SystemeDeFichiersEnLectureSeule";
            expr = "node_filesystem_readonly{${fsSelector}} == 1";
            for = "5m";
            labels.severity = "critical";
            annotations.summary = "{{ $labels.mountpoint }} est passé en lecture seule.";
          }
          {
            # `MemAvailable` et pas `MemFree` : le noyau garde volontairement peu
            # de mémoire libre, l'essentiel servant de cache. Seul le premier dit
            # ce qu'une application pourrait réellement obtenir.
            alert = "MemoireFaible";
            expr = "node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100 < 10";
            for = "30m";
            labels.severity = "warning";
            annotations.summary = "Mémoire disponible à {{ $value | printf \"%.1f\" }} %.";
          }
          {
            alert = "SwapSollicite";
            expr = "(node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes) / node_memory_SwapTotal_bytes * 100 > 50";
            for = "1h";
            labels.severity = "warning";
            annotations.summary = "Swap occupé à {{ $value | printf \"%.1f\" }} % : quelque chose ne tient plus en mémoire.";
          }
          {
            # Sans `for` : un tueur de mémoire a déjà fait son travail quand on
            # l'apprend, attendre une confirmation n'aurait aucun sens.
            alert = "ProcessusTuePourMemoire";
            expr = "increase(node_vmstat_oom_kill[15m]) > 0";
            labels.severity = "critical";
            annotations.summary = "Le noyau a tué au moins un processus faute de mémoire.";
          }
          {
            # Rapportée au NOMBRE DE CŒURS, faute de quoi le seuil ne veut rien
            # dire : une charge de 4 est confortable sur huit cœurs et
            # catastrophique sur un.
            alert = "ChargeElevee";
            expr = "node_load15 > 2 * count without(cpu, mode) (node_cpu_seconds_total{mode=\"idle\"})";
            for = "30m";
            labels.severity = "warning";
            annotations.summary = "Charge sur 15 minutes à {{ $value | printf \"%.1f\" }}, soit plus du double des cœurs disponibles.";
          }
          {
            # RECOUVRE partiellement `notify.discord`, et c'est voulu : celui-ci
            # signale la TRANSITION vers l'échec, celle-là l'ÉTAT qui dure. Une
            # unité tombée pendant que Discord était injoignable n'apparaît que
            # dans la seconde.
            alert = "UniteSystemdEnEchec";
            expr = "node_systemd_unit_state{state=\"failed\"} == 1";
            for = "10m";
            labels.severity = "warning";
            annotations.summary = "L'unité {{ $labels.name }} est en échec.";
          }
          {
            # Pas un détail de confort sur CETTE machine : les codes TOTP
            # d'Authelia sont calculés sur l'heure, et une dérive suffisante les
            # fait tous refuser sans que rien n'explique pourquoi.
            alert = "HorlogeDerive";
            expr = "abs(node_timex_offset_seconds) > 0.05";
            for = "15m";
            labels.severity = "warning";
            annotations.summary = "Horloge décalée de {{ $value | printf \"%.3f\" }} s : les codes TOTP finiront par être refusés.";
          }
        ];
      }

      {
        name = "sondes";
        rules = [
          {
            alert = "SondeEnEchec";
            expr = "probe_success == 0";
            for = "5m";
            labels.severity = "critical";
            annotations.summary = "{{ $labels.instance }} ne répond pas comme attendu.";
          }
          {
            alert = "SondeLente";
            expr = "probe_duration_seconds > 5";
            for = "30m";
            labels.severity = "warning";
            annotations.summary = "{{ $labels.instance }} répond en {{ $value | printf \"%.1f\" }} s.";
          }
          {
            # DOUBLON ASSUMÉ avec `acme-expiry-check` (cf. modules/system/server/proxy),
            # et les deux méritent d'exister : la sonde du proxy vérifie le
            # certificat servi sur la boucle locale et n'a besoin de rien d'autre
            # que d'openssl, celle-ci passe par le même chemin qu'un vrai client
            # et garde un historique. Si l'une des deux tombe, l'autre couvre.
            #
            # Même seuil que là-bas — 21 jours — pour la même raison : lego
            # renouvelle à 30 jours, alerter plus tôt sonnerait à chaque fenêtre
            # de renouvellement normale.
            alert = "CertificatBientotExpire";
            expr = "(probe_ssl_earliest_cert_expiry - time()) / 86400 < 21";
            for = "1h";
            labels.severity = "warning";
            annotations.summary = "Le certificat de {{ $labels.instance }} expire dans {{ $value | printf \"%.0f\" }} jours.";
          }
          {
            alert = "CertificatExpireImminent";
            expr = "(probe_ssl_earliest_cert_expiry - time()) / 86400 < 7";
            for = "10m";
            labels.severity = "critical";
            annotations.summary = "Le certificat de {{ $labels.instance }} expire dans {{ $value | printf \"%.0f\" }} jours, le renouvellement ne se fait plus.";
          }
        ];
      }
    ]
    ++ lib.optional cfg.disks.enable {
      # SANTÉ PHYSIQUE DES DISQUES. C'est le seul groupe de ce module dont les
      # alertes annoncent une perte de DONNÉES et non une interruption de
      # service : tout le reste se répare en redémarrant quelque chose.
      #
      # Il double `smartd`, déjà actif (cf. modules/system/storage/disks), et ça
      # ne fait pas doublon pour autant : smartd n'a que `systembus-notify` comme
      # canal, c'est-à-dire une notification de bureau sur une machine qui n'a
      # aucune session graphique. Il détecte, et personne ne l'entend.
      #
      # Tous les noms de métriques ci-dessous ont été relevés dans le binaire de
      # l'exporteur, pas devinés — une règle qui vise une métrique inexistante
      # ne fait jamais échouer quoi que ce soit, elle ne protège simplement de
      # rien, en silence.
      name = "disques";
      rules = [
        {
          # Le verdict d'ensemble du disque : 0 signifie qu'il s'annonce
          # lui-même comme défaillant. Sur un NVMe, ça n'arrive pas avant que
          # plusieurs indicateurs soient déjà partis.
          alert = "DisqueSmartEnEchec";
          expr = "smartctl_device_smart_status == 0";
          for = "5m";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.device }} se déclare défaillant (SMART). Sauvegarde ce qui compte AVANT de chercher à comprendre.";
        }
        {
          # Bits d'avertissement du contrôleur NVMe : réserve épuisée,
          # température hors plage, média en lecture seule, sauvegarde volatile
          # perdue. N'importe lequel mérite qu'on regarde tout de suite.
          alert = "DisqueAvertissementCritique";
          expr = "smartctl_device_critical_warning > 0";
          for = "5m";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.device }} lève un avertissement critique NVMe (code {{ $value }}).";
        }
        {
          # Blocs de secours sous le seuil que le CONSTRUCTEUR a lui-même fixé,
          # plutôt qu'un pourcentage choisi au hasard : le disque sait mieux que
          # nous à partir de quand il n'a plus de marge.
          alert = "DisqueReserveEpuisee";
          expr = "smartctl_device_available_spare < smartctl_device_available_spare_threshold";
          for = "15m";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.device }} : blocs de secours sous le seuil constructeur, la fin est proche.";
        }
        {
          # Erreurs de média NON CORRIGÉES : chacune est une donnée que le
          # disque n'a pas pu relire. Sans `for`, parce qu'il n'y a rien à
          # confirmer — c'est déjà arrivé.
          alert = "DisqueErreursDeMedia";
          expr = "increase(smartctl_device_media_errors[24h]) > 0";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.device }} : {{ $value | printf \"%.0f\" }} erreur(s) de média non corrigée(s) en 24 h.";
        }
        {
          # Usure d'écriture, en pourcentage de l'endurance prévue. À 85 % le
          # disque fonctionne encore parfaitement : c'est une alerte pour
          # COMMANDER un remplaçant, pas pour intervenir dans l'heure.
          alert = "DisqueUsureElevee";
          expr = "smartctl_device_percentage_used > 85";
          for = "1h";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.device }} a consommé {{ $value | printf \"%.0f\" }} % de son endurance d'écriture.";
        }
      ];
    }
    ++ lib.singleton {
      name = "meta";
      rules = [
      ]
      # CONDITIONNÉE AU DEAD MAN'S SWITCH, seul consommateur qu'elle ait.
      #
      # Elle est toujours en échec par construction, et c'est tout son intérêt :
      # elle ne prévient d'aucun problème, elle PROUVE QUE LA CHAÎNE FONCTIONNE —
      # Prometheus évalue, Alertmanager route, le réseau sort. Alertmanager
      # l'envoie en boucle au tiers ; c'est son ARRÊT qui alerte, hors de cette
      # machine.
      #
      # Sans destinataire, elle n'a plus rien à prouver à personne : elle
      # resterait affichée en permanence dans Alertmanager et dans la source de
      # données Grafana, c'est-à-dire une alerte de fond en face de laquelle on
      # apprend à ne plus regarder. C'est exactement ce qu'une alerte ne doit
      # jamais devenir.
      ++ lib.optional cfg.deadManSwitch.enable {
        alert = "Watchdog";
        expr = "vector(1)";
        labels.severity = "none";
        annotations.summary = "Battement de cœur : cette alerte doit être en échec en permanence.";
      }
      ++ [
        {
          # IRONIE ASSUMÉE : si Discord est injoignable, cette alerte part vers
          # Discord. Elle n'a donc de valeur que pour les pannes PARTIELLES —
          # jeton révoqué, salon supprimé, limitation de débit — où le reste
          # passe encore. La panne totale est couverte par le watchdog, pas par
          # elle.
          alert = "AlertmanagerNEnvoiePlus";
          expr = "rate(alertmanager_notifications_failed_total[15m]) > 0";
          for = "15m";
          labels.severity = "critical";
          annotations.summary = "Alertmanager échoue à notifier ({{ $labels.integration }}) : des alertes sont peut-être perdues.";
        }
        {
          # Une règle qui n'arrive plus à s'évaluer ne dit rien, et son silence
          # ressemble à l'absence de problème.
          alert = "EvaluationDeReglesEnEchec";
          expr = "increase(prometheus_rule_evaluation_failures_total[1h]) > 0";
          for = "10m";
          labels.severity = "warning";
          annotations.summary = "Prometheus n'arrive plus à évaluer certaines règles : elles ne protègent plus de rien.";
        }
      ];
    };
  };

  # TABLEAU DE BORD écrit à la main plutôt qu'importé.
  #
  # Le réflexe est d'importer « Node Exporter Full » (identifiant 1860), qui est
  # excellent — et qui pèse deux cent mille lignes de JSON produites par une
  # machine. Le poser dans ce dépôt-ci, c'est y verser un artefact que personne
  # ne relira jamais en revue, pour cent quatre-vingts panneaux dont on en
  # regarde six.
  #
  # Celui-ci tient en douze panneaux : les quatre chiffres qu'on veut voir
  # d'abord, puis ce dont on a besoin quand on cherche pourquoi. Il reste
  # possible d'importer 1860 à la main depuis l'interface le jour où l'on creuse
  # quelque chose de précis — il vivra alors dans l'état de Grafana, pas ici.
  promDs = {
    type = "prometheus";
    uid = "prometheus";
  };

  mkStat =
    {
      id,
      title,
      x,
      expr,
      unit,
      steps,
    }:
    {
      inherit id title;
      type = "stat";
      datasource = promDs;
      gridPos = {
        h = 4;
        w = 6;
        inherit x;
        y = 0;
      };
      fieldConfig = {
        defaults = {
          inherit unit;
          color.mode = "thresholds";
          thresholds = {
            mode = "absolute";
            inherit steps;
          };
        };
        overrides = [ ];
      };
      options = {
        colorMode = "value";
        graphMode = "area";
        justifyMode = "auto";
        textMode = "auto";
        reduceOptions = {
          calcs = [ "lastNotNull" ];
          fields = "";
          values = false;
        };
      };
      targets = [
        {
          refId = "A";
          datasource = promDs;
          inherit expr;
        }
      ];
    };

  mkTs =
    {
      id,
      title,
      x,
      y,
      targets,
      unit ? "short",
      w ? 12,
      h ? 8,
      min ? 0,
      fill ? 10,
      stack ? false,
    }:
    {
      inherit id title;
      type = "timeseries";
      datasource = promDs;
      gridPos = {
        inherit
          h
          w
          x
          y
          ;
      };
      fieldConfig = {
        defaults = {
          inherit unit min;
          color.mode = "palette-classic";
          custom = {
            drawStyle = "line";
            lineWidth = 1;
            fillOpacity = fill;
            showPoints = "never";
            spanNulls = true;
            stacking = {
              mode = if stack then "normal" else "none";
              group = "A";
            };
          };
        };
        overrides = [ ];
      };
      options = {
        legend = {
          displayMode = "list";
          placement = "bottom";
          showLegend = true;
        };
        tooltip = {
          mode = "multi";
          sort = "desc";
        };
      };
      targets = lib.imap0 (i: t: {
        # `refId` doit seulement être UNIQUE dans le panneau ; les lettres qu'on
        # voit dans l'interface sont une convention, pas une contrainte de
        # format. Une liste de lettres écrite à la main plafonnait à cinq cibles
        # et faisait échouer l'ÉVALUATION DU SYSTÈME à la sixième — une erreur de
        # construction opaque, pour un détail cosmétique. Un compteur n'a pas de
        # borne.
        refId = toString (i + 1);
        datasource = promDs;
        expr = t.expr;
        legendFormat = t.legend;
      }) targets;
    };

  dashboard = {
    uid = "think-systeme";
    title = "Système";
    tags = [ "nix" ];
    timezone = "browser";
    schemaVersion = 39;
    editable = true;
    refresh = "1m";
    time = {
      from = "now-12h";
      to = "now";
    };
    panels = [
      (mkStat {
        id = 1;
        title = "Processeur";
        x = 0;
        unit = "percent";
        expr = "100 * (1 - avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m])))";
        steps = [
          {
            color = "green";
            value = null;
          }
          {
            color = "orange";
            value = 70;
          }
          {
            color = "red";
            value = 90;
          }
        ];
      })
      (mkStat {
        id = 2;
        title = "Mémoire utilisée";
        x = 6;
        unit = "percent";
        expr = "100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)";
        steps = [
          {
            color = "green";
            value = null;
          }
          {
            color = "orange";
            value = 80;
          }
          {
            color = "red";
            value = 90;
          }
        ];
      })
      (mkStat {
        id = 3;
        title = "Racine utilisée";
        x = 12;
        unit = "percent";
        expr = "100 * (1 - node_filesystem_avail_bytes{mountpoint=\"/\"} / node_filesystem_size_bytes{mountpoint=\"/\"})";
        steps = [
          {
            color = "green";
            value = null;
          }
          {
            color = "orange";
            value = 85;
          }
          {
            color = "red";
            value = 95;
          }
        ];
      })
      (mkStat {
        id = 4;
        title = "Sondes en échec";
        x = 18;
        unit = "short";
        expr = "count(probe_success == 0) or vector(0)";
        steps = [
          {
            color = "green";
            value = null;
          }
          {
            color = "red";
            value = 1;
          }
        ];
      })

      (mkTs {
        id = 10;
        title = "Processeur par mode";
        x = 0;
        y = 4;
        unit = "percentunit";
        stack = true;
        fill = 30;
        targets = [
          {
            expr = "sum by (mode) (rate(node_cpu_seconds_total{mode!=\"idle\"}[5m])) / on() group_left count without(cpu, mode) (node_cpu_seconds_total{mode=\"idle\"})";
            legend = "{{ mode }}";
          }
        ];
      })
      (mkTs {
        id = 11;
        title = "Mémoire";
        x = 12;
        y = 4;
        unit = "bytes";
        targets = [
          {
            expr = "node_memory_MemTotal_bytes";
            legend = "totale";
          }
          {
            expr = "node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes";
            legend = "utilisée";
          }
          {
            expr = "node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes";
            legend = "swap";
          }
        ];
      })

      (mkTs {
        id = 12;
        title = "Espace disque libre";
        x = 0;
        y = 12;
        unit = "bytes";
        targets = [
          {
            expr = "node_filesystem_avail_bytes{${fsSelector}}";
            legend = "{{ mountpoint }}";
          }
        ];
      })
      (mkTs {
        id = 13;
        title = "Charge";
        x = 12;
        y = 12;
        unit = "short";
        targets = [
          {
            expr = "node_load1";
            legend = "1 min";
          }
          {
            expr = "node_load5";
            legend = "5 min";
          }
          {
            expr = "node_load15";
            legend = "15 min";
          }
          {
            expr = "count without(cpu, mode) (node_cpu_seconds_total{mode=\"idle\"})";
            legend = "cœurs";
          }
        ];
      })

      (mkTs {
        id = 14;
        title = "Réseau";
        x = 0;
        y = 20;
        unit = "Bps";
        min = null;
        targets = [
          {
            expr = "rate(node_network_receive_bytes_total{device!~\"lo|docker.*|veth.*\"}[5m])";
            legend = "↓ {{ device }}";
          }
          {
            expr = "-rate(node_network_transmit_bytes_total{device!~\"lo|docker.*|veth.*\"}[5m])";
            legend = "↑ {{ device }}";
          }
        ];
      })
      (mkTs {
        id = 15;
        title = "Disque";
        x = 12;
        y = 20;
        unit = "Bps";
        min = null;
        targets = [
          {
            expr = "rate(node_disk_read_bytes_total[5m])";
            legend = "lecture {{ device }}";
          }
          {
            expr = "-rate(node_disk_written_bytes_total[5m])";
            legend = "écriture {{ device }}";
          }
        ];
      })

      (mkTs {
        id = 16;
        title = "Temps de réponse des sondes";
        x = 0;
        y = 28;
        unit = "s";
        targets = [
          {
            expr = "probe_duration_seconds";
            legend = "{{ instance }}";
          }
        ];
      })
      (mkTs {
        id = 17;
        title = "Certificats — jours restants";
        x = 12;
        y = 28;
        unit = "short";
        targets = [
          {
            expr = "(probe_ssl_earliest_cert_expiry - time()) / 86400";
            legend = "{{ instance }}";
          }
        ];
      })
    ]
    # Deux courbes qui ne bougent qu'en mois, et c'est exactement pourquoi elles
    # méritent un panneau : leur PENTE dit quand commander un remplaçant, bien
    # avant que le seuil d'alerte soit franchi.
    ++ lib.optional cfg.disks.enable (mkTs {
      id = 18;
      title = "Disques — usure et réserve";
      x = 0;
      y = 36;
      w = 24;
      unit = "percent";
      targets = [
        {
          expr = "smartctl_device_percentage_used";
          legend = "usure {{ device }}";
        }
        {
          expr = "smartctl_device_available_spare";
          legend = "réserve {{ device }}";
        }
      ];
    });
  };

  dashboardsDir = pkgs-stable.linkFarm "grafana-dashboards" [
    {
      name = "systeme.json";
      path = pkgs-stable.writeText "systeme.json" (builtins.toJSON dashboard);
    }
  ];
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
        HTTP.

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

                `http_authelia` accepte aussi la redirection vers le portail, qui
                est la réponse NORMALE d'un nom protégé sondé depuis le host. Il
                ne prouve que nginx, le certificat et Authelia ; l'application
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

          POURQUOI C'EST À PART du reste des métriques : c'est la seule chose
          surveillée ici dont la défaillance détruit des DONNÉES au lieu
          d'interrompre un service. Un service qui tombe se relance, un disque
          qui meurt ne rend rien.

          Ça ne remplace pas `smartd`, qui tourne déjà (cf.
          modules/system/storage/disks) : celui-ci surveille en continu et sait
          lancer des autotests, ce que l'exporteur ne fait pas. Ça lui donne le
          canal qui lui manque — smartd ne sait notifier que par
          `systembus-notify`, c'est-à-dire une notification de bureau sur une
          machine qui n'a aucune session graphique. Il détecte depuis toujours,
          et personne ne l'entend.

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
          construction : il ne s'interrompt donc pas seulement quand la machine
          meurt, mais aussi quand Prometheus n'évalue plus ses règles ou
          qu'Alertmanager ne route plus. Toute la chaîne est prouvée, pas
          seulement la présence de la machine.

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
        assertion = config.systemSettings.proxy.enable;
        message = "systemSettings.monitoring exige systemSettings.proxy.enable (nginx et le certificat du vhost Grafana).";
      }
      {
        assertion = !cfg.grafana.public || config.systemSettings.cloudflared.enable;
        message = "systemSettings.monitoring.grafana.public exige systemSettings.cloudflared.enable, aucun port n'étant ouvert sur la box.";
      }
    ];

    warnings = lib.optional (!cfg.deadManSwitch.enable) ''
      systemSettings.monitoring : aucun dead man's switch sur ce host.
      Prometheus, Alertmanager et le notifieur Discord tournent tous SUR la machine surveillée :
      si elle s'arrête, plus rien n'est envoyé et le silence ressemble exactement à « tout va bien ».
      Active systemSettings.monitoring.deadManSwitch.
    '';

    # ---------------------------------------------------------------- collecte

    services.prometheus = {
      enable = true;
      # Boucle locale : rien n'a besoin de joindre Prometheus depuis le réseau,
      # et son interface d'exploration donne accès à TOUTES les métriques sans
      # la moindre authentification — c'est Grafana, derrière le portail, qui
      # sert de façade.
      listenAddress = "127.0.0.1";
      port = ports.prometheus;
      retentionTime = cfg.retention;

      globalConfig = {
        scrape_interval = cfg.scrapeInterval;
        evaluation_interval = cfg.scrapeInterval;
      };

      rules = [ (builtins.toJSON alertRules) ];

      alertmanagers = [
        { static_configs = [ { targets = [ "127.0.0.1:${toString ports.alertmanager}" ]; } ]; }
      ];

      scrapeConfigs = [
        {
          job_name = "prometheus";
          static_configs = [ { targets = [ "127.0.0.1:${toString ports.prometheus}" ]; } ];
        }
        {
          job_name = "node";
          static_configs = [ { targets = [ "127.0.0.1:${toString ports.node}" ]; } ];
        }
        {
          # Se surveiller lui-même a un sens précis ici : c'est de ses métriques
          # que vient `AlertmanagerNEnvoiePlus`.
          job_name = "alertmanager";
          static_configs = [ { targets = [ "127.0.0.1:${toString ports.alertmanager}" ]; } ];
        }
      ]
      ++ lib.optional cfg.disks.enable {
        job_name = "smartctl";
        # L'exporteur ne réinterroge de toute façon pas les disques plus d'une
        # fois par minute (`maxInterval`), et une lecture SMART n'est pas
        # gratuite : la collecter toutes les trente secondes ne ferait que
        # dupliquer la même valeur.
        scrape_interval = "1m";
        static_configs = [ { targets = [ "127.0.0.1:${toString ports.smartctl}" ]; } ];
      }
      ++ lib.optional (cloudflared.metricsAddress != null) {
        # LE SEUL MOYEN DE VOIR L'ÉTAT DU TUNNEL — cf. la documentation de
        # `systemSettings.cloudflared.metricsAddress`, qui porte le raisonnement
        # et le nom de l'unité à modifier.
        #
        # `up == 0` sur cette tâche attrape déjà le démon qui ne répond plus.
        # Une règle sur le NOMBRE de connexions vers l'edge serait plus fine,
        # mais les noms de métriques de cloudflared s'assemblent à l'exécution et
        # ne se lisent pas dans le binaire : à écrire une fois qu'on aura vu sa
        # page /metrics, plutôt que devinée maintenant.
        job_name = "cloudflared";
        static_configs = [ { targets = [ cloudflared.metricsAddress ]; } ];
      }
      ++ blackboxJobs;
    };

    services.prometheus.exporters.node = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = ports.node;

      # UN SEUL collecteur ajouté, et il est consommé : `systemd` porte à lui
      # seul la règle `UniteSystemdEnEchec`. Il parle à systemd par dbus ; le
      # module amont ouvre AF_UNIX quand il est demandé, sans quoi le service
      # démarrerait en ne rapportant rien.
      #
      # `processes` a été RETIRÉ : il était activé sans qu'aucune règle ni aucun
      # panneau ne lise ce qu'il produit. Un collecteur qu'on allume « au cas
      # où » coûte des séries à stocker et donne l'illusion d'une surveillance
      # qui n'existe pas. À rallumer le jour où une règle en aura besoin.
      #
      # Les autres viennent par défaut : cpu, mémoire, systèmes de fichiers,
      # réseau, disque, vmstat (dont `oom_kill`) et timex (la dérive d'horloge).
      enabledCollectors = [ "systemd" ];
    };

    services.prometheus.exporters.smartctl = lib.mkIf cfg.disks.enable {
      enable = true;
      listenAddress = "127.0.0.1";
      port = ports.smartctl;
      inherit (cfg.disks) devices;
    };

    # CONDITIONNÉ À L'EXISTENCE DE CIBLES, et pas seulement par économie.
    #
    # Le point d'entrée `/probe` de cet exporteur prend l'URL à sonder en
    # PARAMÈTRE : quiconque peut lui parler fait émettre à cette machine une
    # requête HTTP vers la destination de son choix. C'est un relais de requêtes
    # en bonne et due forme. Il n'écoute que sur la boucle locale, donc ça
    # suppose déjà un accès à la machine — raison de plus pour ne pas le faire
    # tourner quand aucune sonde n'est déclarée.
    services.prometheus.exporters.blackbox = lib.mkIf (cfg.blackbox.targets != { }) {
      enable = true;
      listenAddress = "127.0.0.1";
      port = ports.blackbox;
      configFile = blackboxConfig;
    };

    # --------------------------------------------------------------- alerting

    services.prometheus.alertmanager = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = ports.alertmanager;

      configuration = {
        route = {
          receiver = "discord";

          # Regroupement par ALERTE et non par instance : un disque plein
          # déclenche `DisqueBientotPlein` sur plusieurs points de montage à la
          # fois, et c'est un seul message qu'on veut lire.
          group_by = [ "alertname" ];
          group_wait = "30s";
          group_interval = "5m";

          # Douze heures avant de répéter : assez pour qu'une alerte ignorée
          # revienne, assez peu pour qu'elle n'apprenne pas à être ignorée.
          repeat_interval = "12h";

          # Le battement de cœur, qui ne doit RIEN à la logique de regroupement :
          # ni attente, ni espacement, ni la répétition de douze heures. Il part
          # immédiatement et repart à chaque période.
          #
          # La route ET la règle qui l'alimente apparaissent ensemble ou pas du
          # tout (cf. le groupe `meta`). Une route sans sa règle serait morte ;
          # une règle sans sa route, pire — l'alerte perpétuelle retomberait sur
          # le receveur par défaut et partirait sur Discord toutes les cinq
          # minutes, indéfiniment.
          routes = lib.optional cfg.deadManSwitch.enable {
            receiver = "deadman";
            matchers = [ ''alertname="Watchdog"'' ];
            group_wait = "0s";
            group_interval = "1m";
            repeat_interval = cfg.deadManSwitch.interval;
          };
        };

        # Un disque à 96 % déclenche AUSSI la règle à 85 % : sans cette
        # inhibition, deux messages pour le même problème, dont un qui minimise.
        inhibit_rules = [
          {
            source_matchers = [ ''severity="critical"'' ];
            target_matchers = [ ''severity="warning"'' ];
            equal = [
              "alertname"
              "instance"
            ];
          }
        ];

        receivers = [
          {
            name = "discord";
            discord_configs = [
              {
                # Receveur Discord NATIF (depuis Alertmanager 0.25), pas un pont
                # à installer. L'URL vient d'un fichier et jamais de la
                # configuration : celle-ci vit dans le store, lisible par tous
                # les utilisateurs de la machine.
                webhook_url_file = "${amCredentials}/discord_webhook";
                send_resolved = true;
                title = ''{{ if eq .Status "firing" }}🔴 {{ .Alerts.Firing | len }} × {{ .CommonLabels.alertname }}{{ else }}🟢 Résolu — {{ .CommonLabels.alertname }}{{ end }}'';
                message = ''
                  {{ range .Alerts -}}
                  **{{ .Labels.severity }}** · `{{ .Labels.instance }}`
                  {{ .Annotations.summary }}
                  {{ end }}
                '';
              }
            ];
          }
        ]
        # Troisième et dernière pièce du dead man's switch, avec sa règle et sa
        # route : les trois apparaissent ensemble ou aucune. Un receveur défini
        # sans route qui le vise est du mobilier mort dans la configuration.
        #
        # Un POST sur l'URL de ping, ce qu'attend healthchecks.io — le corps JSON
        # qu'Alertmanager y met est simplement journalisé chez eux.
        #
        # `send_resolved` à faux et `max_alerts` à un : cette route ne transporte
        # qu'une alerte qui ne se résout jamais, tout le reste serait du bruit
        # envoyé à un tiers.
        ++ lib.optional cfg.deadManSwitch.enable {
          name = "deadman";
          webhook_configs = [
            {
              url_file = "${amCredentials}/healthchecks_ping";
              send_resolved = false;
              max_alerts = 1;
            }
          ];
        };
      };
    };

    # Le webhook est DÉJÀ déclaré par modules/system/notify, mais on le redéclare
    # ici : ce module doit fonctionner même si le signalement d'échec d'unité est
    # coupé, et c'est cette déclaration-là qui fait entrer alertmanager dans
    # l'audience du secret (cf. lib/sops-policy.nix). Les deux définitions
    # fusionnent, aucune ne pose `mode` deux fois.
    #
    # `restartUnits` : alertmanager ne relit pas ses credentials, une rotation du
    # webhook resterait sans effet jusqu'au prochain redémarrage fortuit.
    sops.secrets = lib.mkMerge [
      { ${notify.webhookKey}.restartUnits = [ "alertmanager.service" ]; }

      (lib.mkIf cfg.deadManSwitch.enable {
        ${cfg.deadManSwitch.pingUrlKey} = {
          mode = "0400";
          restartUnits = [ "alertmanager.service" ];
        };
      })
    ];

    # ---------------------------------------------------------------- Grafana

    services.grafana = {
      enable = true;

      settings = {
        server = {
          http_addr = "127.0.0.1";
          http_port = ports.grafana;
          domain = cfg.grafana.hostName;
          # Sans lui, les liens que Grafana fabrique (partage, retour de
          # connexion) pointent vers localhost:3000.
          root_url = "https://${cfg.grafana.hostName}/";
        };

        analytics = {
          reporting_enabled = false;
          check_for_updates = false;
          feedback_links_enabled = false;
        };
        news.news_feed_enabled = false;

        # AUTHENTIFICATION DÉLÉGUÉE AU PORTAIL, et c'est le point le plus délicat
        # du module.
        #
        # Le principe : Authelia authentifie, nginx transmet l'identité dans un
        # en-tête, Grafana fait confiance à cet en-tête et ouvre la session. Plus
        # aucun mot de passe Grafana à gérer, donc plus aucun secret de plus dans
        # sops, et une seule connexion au lieu de deux.
        #
        # CE QUI LE REND SÛR tient à trois conditions, toutes vérifiables :
        #
        #   1. Grafana n'écoute que sur 127.0.0.1 : personne ne peut lui parler
        #      sans passer par nginx.
        #   2. nginx pose l'en-tête avec `proxy_set_header`, qui REMPLACE ce que
        #      le client a envoyé. Un visiteur qui fabrique un `X-WEBAUTH-USER`
        #      le voit écrasé par la valeur qu'Authelia a renvoyée (cf. le vhost
        #      plus bas).
        #   3. `whitelist` restreint la confiance à la boucle locale, seule
        #      adresse d'où nginx se connecte.
        #
        # Retirer l'une des trois suffit à transformer un en-tête en droit
        # d'administration.
        "auth.proxy" = {
          enabled = true;
          header_name = "X-WEBAUTH-USER";
          header_property = "username";
          headers = "Name:X-WEBAUTH-NAME Email:X-WEBAUTH-EMAIL";
          auto_sign_up = true;
          sync_ttl = 60;
          whitelist = "127.0.0.1";
          enable_login_token = false;
        };

        auth = {
          # Formulaire de connexion COUPÉ : le laisser afficherait une porte
          # dérobée protégée par le mot de passe admin par défaut de Grafana.
          #
          # CONTREPARTIE, à connaître avant d'en avoir besoin : si Authelia cesse
          # de renvoyer l'identité, plus personne n'entre, y compris par un
          # tunnel SSH vers 127.0.0.1:3000. La porte de secours est de remettre
          # cette ligne à `false` le temps d'un rebuild, puis
          # `grafana-cli admin reset-admin-password <mot de passe>`.
          disable_login_form = true;
          disable_signout_menu = true;
        };
        "auth.anonymous".enabled = false;
        "auth.basic".enabled = false;

        users = {
          allow_sign_up = false;

          # `Editor` ET NON `Admin`, et l'écart est plus grand qu'il n'y paraît.
          #
          # Ce qu'un Editor peut faire couvre tout l'usage réel : explorer les
          # métriques, écrire des requêtes, créer et modifier des tableaux de
          # bord. Ce qu'il ne peut PAS faire est précisément ce qui est dangereux
          # ici — AJOUTER UNE SOURCE DE DONNÉES. Grafana interroge ses sources
          # depuis le serveur, donc quiconque peut en déclarer une fait émettre à
          # cette machine des requêtes vers l'adresse de son choix, y compris des
          # services de la boucle locale qui ne sont exposés nulle part :
          # Prometheus, Alertmanager, l'API d'Authelia. C'est un relais de
          # requêtes complet, offert par une interface graphique.
          #
          # Ça ne coûte rien parce que les sources sont POSÉES PAR LE DÉPÔT juste
          # en dessous : il n'y a jamais eu de raison d'en ajouter à la main.
          #
          # La barrière principale reste la règle Authelia, qui doit désigner
          # NOMMÉMENT les comptes admis (`subject`) — les comptes familiaux ont
          # eux aussi accès au portail. Celle-ci en est la seconde, pour le jour
          # où la première serait relâchée par inadvertance.
          auto_assign_org_role = "Editor";
        };

        security = {
          cookie_secure = true;

          # Clé qui chiffre les secrets rangés dans la base de Grafana — mots de
          # passe de sources de données, jetons de points de contact. Depuis
          # 26.05 elle n'a plus de valeur par défaut, et le module amont refuse
          # de construire sans elle.
          #
          # NI EN CLAIR ICI, NI DANS SOPS, mais engendrée sur la machine au
          # premier démarrage (cf. le preStart plus bas). En clair, elle finirait
          # dans le store et dans ce dépôt public, ce qui reviendrait à ne rien
          # chiffrer. Dans sops, elle laisserait croire à un secret transportable
          # alors qu'elle ne vaut QUE pour la base qu'elle a chiffrée : la
          # restaurer sur une machine dont la base est vide n'apporte rien, et la
          # perdre en gardant la base rend celle-ci illisible. Clé et base sont
          # le même état local, elles vivent au même endroit.
          #
          # `$__file{}` est le mécanisme de Grafana lui-même : il lit le contenu
          # du fichier au démarrage.
          secret_key = "$__file{${config.services.grafana.dataDir}/secret_key}";
        };
      };

      # Sources et tableaux de bord POSÉS PAR LE DÉPÔT, jamais cliqués. C'est ce
      # qui fait qu'une réinstallation rend une instance identique et pas une
      # instance vide — le reproche principal qu'on peut faire aux outils dont
      # toute la configuration vit dans une base.
      provision = {
        enable = true;

        datasources.settings = {
          apiVersion = 1;
          datasources = [
            {
              name = "Prometheus";
              type = "prometheus";
              # `uid` FIXE, et c'est ce qui rend le tableau de bord ci-dessus
              # portable : un panneau référence sa source par uid, et un uid
              # engendré au hasard changerait à chaque réinstallation, laissant
              # des panneaux vides.
              uid = "prometheus";
              access = "proxy";
              url = "http://127.0.0.1:${toString ports.prometheus}";
              isDefault = true;
              jsonData.timeInterval = cfg.scrapeInterval;
            }
            {
              name = "Alertmanager";
              type = "alertmanager";
              uid = "alertmanager";
              access = "proxy";
              url = "http://127.0.0.1:${toString ports.alertmanager}";
              jsonData.implementation = "prometheus";
            }
          ];
        };

        dashboards.settings = {
          apiVersion = 1;
          providers = [
            {
              name = "dépôt";
              type = "file";
              # Modification interdite depuis l'interface : le fichier vient du
              # store, donc en lecture seule de toute façon. Le dire à Grafana
              # évite de laisser croire qu'un changement a été enregistré.
              allowUiUpdates = false;
              disableDeletion = true;
              options.path = dashboardsDir;
            }
          ];
        };
      };
    };

    # ------------------------------------------------------------- publication

    services.nginx.virtualHosts.${cfg.grafana.hostName} = lib.mkMerge [
      (myLib.mkTlsVhost {
        # Adresse réelle plutôt que celle de la connexion TCP, comme le portail :
        # tout arrive par cloudflared en 127.0.0.1 quand on vient de l'extérieur.
        extraConfig = ''
          access_log /var/log/nginx/access.log cf_combined;
        '';

        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString ports.grafana}";
          # Grafana Live pousse ses mises à jour par websocket.
          proxyWebsockets = true;

          extraConfig = ''
            # LES DEUX LIGNES CI-DESSOUS SONT RECOPIÉES du niveau server, où
            # `authelia.nginxProtect` les pose déjà. Ce n'est pas une redondance,
            # c'est une obligation : `auth_request_set` suit la même règle
            # d'héritage que `add_header`, à savoir qu'un niveau qui en déclare
            # UN SEUL REMPLACE toute la liste du parent au lieu de s'y ajouter.
            #
            # Les trois `auth_request_set` de l'identité, juste en dessous,
            # suffisaient donc à effacer ceux du parent. `$redirection_url`
            # restait vide, `@authelia_401` en concluait que le 401 venait de
            # l'application et servait un 401 sec — en avalant la redirection
            # vers le portail qu'Authelia avait pourtant renvoyée. Symptôme :
            # 401 sans en-tête `Location` sur un nom protégé, alors que le même
            # montage marche sur Nextcloud, dont le vhost n'ajoute aucun
            # `auth_request_set`. Constaté par la sonde blackbox.
            #
            # SI TU AJOUTES un `auth_request_set` ici, vérifie que ces deux-là y
            # sont toujours.
            auth_request_set $redirection_url $upstream_http_location;
            auth_request_set $auth_status $upstream_status;

            # IDENTITÉ RENVOYÉE PAR AUTHELIA, reprise de la sous-requête
            # d'autorisation et repassée à Grafana. `$upstream_http_remote_user`
            # est l'en-tête `Remote-User` de la RÉPONSE d'Authelia — donc une
            # valeur qu'il a produite, pas une valeur que le client a envoyée.
            auth_request_set $authelia_user $upstream_http_remote_user;
            auth_request_set $authelia_name $upstream_http_remote_name;
            auth_request_set $authelia_email $upstream_http_remote_email;

            # `proxy_set_header` REMPLACE l'en-tête du client, il ne s'y ajoute
            # pas : c'est ce qui rend l'identité infalsifiable depuis dehors.
            # Ne jamais retirer ces trois lignes en laissant `auth.proxy` actif,
            # ce serait ouvrir l'administration de Grafana à un en-tête.
            proxy_set_header X-WEBAUTH-USER $authelia_user;
            proxy_set_header X-WEBAUTH-NAME $authelia_name;
            proxy_set_header X-WEBAUTH-EMAIL $authelia_email;
          '';
        };
      })

      # Portail devant le vhost. `nginxProtect` et non `nginxAuthRequest` :
      # contrairement à Nextcloud, rien derrière n'émet de 401 qu'il faudrait
      # préserver — le formulaire de connexion de Grafana est coupé, c'est
      # Authelia qui refuse, et sa redirection doit être suivie.
      authelia.nginxProtect
    ];

    systemSettings.cloudflared = lib.mkMerge [
      (lib.mkIf cfg.grafana.public {
        ingress.${cfg.grafana.hostName} = "https://127.0.0.1:443";
      })

      # DEMANDE au module du tunnel d'ouvrir sa page de métriques, au lieu
      # d'aller modifier son unité systemd de l'extérieur. C'est lui qui connaît
      # le nom de cette unité, construit à partir de l'UUID par le module amont.
      #
      # `mkDefault` : la valeur reste écrasable depuis un profil, et surtout un
      # `metricsAddress` déjà posé ailleurs n'entre pas en conflit avec celle-ci.
      (lib.mkIf cloudflared.enable {
        metricsAddress = lib.mkDefault "127.0.0.1:2000";
      })
    ];

    # ------------------------------------------------------------------ unités

    systemd.services = lib.mkMerge [
      {
        alertmanager = {
          serviceConfig.LoadCredential = [
            "discord_webhook:${config.sops.secrets.${notify.webhookKey}.path}"
          ]
          ++ lib.optional cfg.deadManSwitch.enable "healthchecks_ping:${
            config.sops.secrets.${cfg.deadManSwitch.pingUrlKey}.path
          }";
        };
      }

      {
        # Engendre la clé de chiffrement de la base au premier démarrage, et
        # seulement s'il n'y en a pas : la RÉÉCRIRE rendrait illisible tout ce
        # qu'elle a déjà chiffré.
        #
        # `mkAfter` : le module amont a son propre preStart, qui pose les liens
        # vers les ressources de Grafana. On s'ajoute derrière au lieu de le
        # remplacer.
        grafana.preStart = lib.mkAfter ''
          key=${config.services.grafana.dataDir}/secret_key
          if [ ! -s "$key" ]; then
            umask 077
            # Sans saut de ligne final : Grafana lit le fichier tel quel.
            ${pkgs-stable.coreutils}/bin/head -c 32 /dev/urandom \
              | ${pkgs-stable.coreutils}/bin/base64 \
              | ${pkgs-stable.coreutils}/bin/tr -d '\n' > "$key"
            ${pkgs-stable.coreutils}/bin/chmod 0400 "$key"
          fi
        '';
      }

      (lib.mkIf (cfg.disks.enable && notify.enable) {
        prometheus-smartctl-exporter = notify.onFailure;
      })

      # Ces unités-là ne se surveillent pas elles-mêmes : Prometheus arrêté
      # n'évalue plus la règle qui dirait qu'il est arrêté. Le signalement
      # d'échec d'unité est le seul filet sur ce cas, d'où ce raccordement.
      (lib.mkIf notify.enable {
        prometheus = notify.onFailure;
        alertmanager = notify.onFailure;
        grafana = notify.onFailure;
        prometheus-node-exporter = notify.onFailure;
        prometheus-blackbox-exporter = notify.onFailure;
      })
    ];
  };
}
