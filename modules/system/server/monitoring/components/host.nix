{
  config,
  lib,
  myLib,
  ...
}:

# node_exporter : ce que la machine sait d'elle-même — disque, mémoire, charge,
# état des unités systemd, dérive d'horloge, températures, timers.
let
  cfg = config.systemSettings.monitoring;
  inherit (cfg.internal) ports helpers;
  inherit (myLib.server.grafana)
    mkStat
    mkTs
    steps
    byName
    thresholdLine
    ;

  # Seuils partagés entre une règle et le panneau qui la montre : écrits une
  # fois, le panneau ne peut pas dire autre chose que l'alerte.
  seuils = {
    # Charge sur 15 min, en multiple du nombre de cœurs.
    chargeParCoeur = 2;
    # Ancienneté du dernier déclenchement d'un timer quotidien : deux périodes.
    timerSecondes = 48 * 3600;
  };

  # Nombre de cœurs. Un scalaire sans étiquette : le diviser à une série
  # étiquetée demande `on() group_left`, sans quoi PromQL ne sait pas apparier
  # les deux membres et rend un résultat vide — sans erreur.
  coeurs = ''count without(cpu, mode) (node_cpu_seconds_total{mode="idle"})'';

  # Filtre commun aux règles et panneaux sur les systèmes de fichiers.
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

  # Timers dont le silence coûte quelque chose. Les hebdomadaires (`fstrim`,
  # `nix-gc`) sont volontairement exclus : ils demanderaient un autre seuil, et
  # leur arrêt ne casse rien d'immédiat.
  timersSurveilles = ''node_systemd_timer_last_trigger_seconds{name=~"nixos-upgrade.timer|acme-.+"}'';

  # Seuil de température : 90 % de la limite que le matériel déclare.
  seuilTemperature = "0.9 * node_hwmon_temp_crit_celsius";
in
{
  config = lib.mkIf cfg.enable {
    services.prometheus.exporters.node = helpers.mkLocalExporter ports.node // {
      # UN SEUL collecteur ajouté, et il est consommé : `systemd` porte à lui
      # seul la règle `UniteSystemdEnEchec`. Il parle à systemd par dbus ; le
      # module amont ouvre AF_UNIX quand il est demandé, sans quoi le service
      # démarrerait en ne rapportant rien.
      #
      # Pas de `processes` : aucun panneau ni aucune règle ne lit ce qu'il
      # produit. Un collecteur qu'on allume « au cas où » coûte des séries à
      # stocker et donne l'illusion d'une surveillance qui n'existe pas.
      #
      # Les autres viennent par défaut : cpu, mémoire, systèmes de fichiers,
      # réseau, disque, vmstat (dont `oom_kill`), timex (la dérive d'horloge),
      # hwmon et pressure.
      enabledCollectors = [ "systemd" ];

      # COMPTEUR DE REDÉMARRAGES PAR UNITÉ, qui ferme un angle mort réel : le
      # service qui redémarre en boucle sans jamais échouer.
      #
      # `Restart = on-failure` avec `StartLimitBurst = 5` — la configuration des
      # conteneurs podman — a un trou précis. Un service qui plante VITE épuise
      # ses cinq tentatives, passe en `failed`, et `UniteSystemdEnEchec`
      # l'attrape. Un service qui plante LENTEMENT, une fois par minute, ne
      # franchit jamais la limite : il redémarre indéfiniment, l'unité reste
      # `active`, et rien ne le voit.
      #
      # Nom relevé en lançant l'exporteur avec ce drapeau, pas supposé :
      # `node_systemd_service_restart_total`, étiqueté par `name`.
      extraFlags = [ "--collector.systemd.enable-restarts-metrics" ];
    };

    # node_exporter porte la quasi-totalité des règles : sa panne rend muettes
    # des dizaines d'autres alertes et vaut d'être connue tout de suite, sans
    # attendre les cinq minutes de `CibleInjoignable`.
    systemSettings.notify.discord.units = [ "prometheus-node-exporter" ];

    systemSettings.monitoring.internal = {
      scrapeJobs.node = helpers.localJob "node" ports.node // {
        # node_exporter reprend verbatim les noms de `/proc/vmstat`, qui
        # ignorent la convention du suffixe. Cf. `suffixeTotal`.
        metric_relabel_configs = helpers.suffixeTotal "node_vmstat_oom_kill";
      };

      alertRules = {
        DisqueBientotPlein = {
          alert = "DisqueBientotPlein";
          expr = "100 * (1 - node_filesystem_avail_bytes{${fsSelector}} / node_filesystem_size_bytes{${fsSelector}}) > 85";
          for = "30m";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.mountpoint }} occupé à {{ $value | printf \"%.1f\" }} %.";
        };

        DisquePresquePlein = {
          alert = "DisquePresquePlein";
          expr = "100 * (1 - node_filesystem_avail_bytes{${fsSelector}} / node_filesystem_size_bytes{${fsSelector}}) > 95";
          for = "5m";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.mountpoint }} occupé à {{ $value | printf \"%.1f\" }} %, la machine va commencer à casser.";
          # Deux points de montage qui se remplissent ensemble restent deux
          # alertes, d'où `mountpoint`.
          inhibits = {
            alertname = "DisqueBientotPlein";
            equal = [
              "instance"
              "mountpoint"
            ];
          };
        };

        # La SEULE règle qui prévient AVANT que le seuil soit atteint : elle
        # extrapole la pente des six dernières heures. Le second terme n'est pas
        # décoratif — sans lui, un disque à 4 % d'occupation qui gagne un
        # mégaoctet déclencherait l'alerte au moindre bruit de mesure.
        DisquePleinEnTroisJours = {
          alert = "DisquePleinEnTroisJours";
          expr = "predict_linear(node_filesystem_avail_bytes{${fsSelector}}[6h], 3 * 24 * 3600) < 0 and node_filesystem_avail_bytes{${fsSelector}} / node_filesystem_size_bytes{${fsSelector}} < 0.4";
          for = "1h";
          labels.severity = "warning";
          annotations.summary = "Au rythme actuel, {{ $labels.mountpoint }} sera plein d'ici trois jours.";
        };

        # Se remplit indépendamment de l'espace, et le message d'erreur qui en
        # découle (« No space left on device » sur un disque à moitié vide) est
        # parmi les plus déroutants qui soient.
        InodesEpuises = {
          alert = "InodesEpuises";
          expr = "node_filesystem_files_free{${fsSelector}} / node_filesystem_files{${fsSelector}} * 100 < 10";
          for = "30m";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.mountpoint }} : plus que {{ $value | printf \"%.1f\" }} % d'inodes libres.";
        };

        # Bascule que le noyau opère seul quand il trouve une corruption. La
        # machine continue de tourner et de répondre, mais plus rien ne s'écrit
        # — c'est la panne la plus silencieuse de la liste.
        SystemeDeFichiersEnLectureSeule = {
          alert = "SystemeDeFichiersEnLectureSeule";
          expr = "node_filesystem_readonly{${fsSelector}} == 1";
          for = "5m";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.mountpoint }} est passé en lecture seule.";
        };

        # `MemAvailable` et pas `MemFree` : le noyau garde volontairement peu de
        # mémoire libre, l'essentiel servant de cache. Seul le premier dit ce
        # qu'une application pourrait réellement obtenir.
        MemoireFaible = {
          alert = "MemoireFaible";
          expr = "node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100 < 10";
          for = "30m";
          labels.severity = "warning";
          annotations.summary = "Mémoire disponible à {{ $value | printf \"%.1f\" }} %.";
        };

        SwapSollicite = {
          alert = "SwapSollicite";
          expr = "(node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes) / node_memory_SwapTotal_bytes * 100 > 50";
          for = "1h";
          labels.severity = "warning";
          annotations.summary = "Swap occupé à {{ $value | printf \"%.1f\" }} % : quelque chose ne tient plus en mémoire.";
        };

        # Sans `for` : un tueur de mémoire a déjà fait son travail quand on
        # l'apprend, attendre une confirmation n'aurait aucun sens.
        ProcessusTuePourMemoire = {
          alert = "ProcessusTuePourMemoire";
          expr = "increase(node_vmstat_oom_kill_total[15m]) > 0";
          labels.severity = "critical";
          annotations.summary = "Le noyau a tué au moins un processus faute de mémoire.";
        };

        # Rapportée au NOMBRE DE CŒURS, faute de quoi le seuil ne veut rien
        # dire : une charge de 4 est confortable sur huit cœurs et catastrophique
        # sur un.
        ChargeElevee = {
          alert = "ChargeElevee";
          expr = "node_load15 > ${toString seuils.chargeParCoeur} * ${coeurs}";
          for = "30m";
          labels.severity = "warning";
          annotations.summary = "Charge sur 15 minutes à {{ $value | printf \"%.1f\" }}, soit plus du double des cœurs disponibles.";
        };

        # RECOUVRE partiellement `notify.discord`, et c'est voulu : celui-ci
        # signale la TRANSITION vers l'échec, celle-là l'ÉTAT qui dure. Une unité
        # tombée pendant que Discord était injoignable n'apparaît que dans la
        # seconde.
        UniteSystemdEnEchec = {
          alert = "UniteSystemdEnEchec";
          expr = "node_systemd_unit_state{state=\"failed\"} == 1";
          for = "10m";
          labels.severity = "warning";
          annotations.summary = "L'unité {{ $labels.name }} est en échec.";
        };

        # LE SERVICE QUI RENAÎT SANS JAMAIS MOURIR. `UniteSystemdEnEchec` voit
        # l'état `failed` ; celle-ci voit ce qui ne l'atteint jamais — un
        # conteneur dont l'amont disparaît par intermittence redémarre toutes les
        # minutes sans épuiser `StartLimitBurst`, et la sonde HTTP le trouve
        # debout entre deux morts.
        #
        # TROIS PAR HEURE comme seuil, et pas un : un rebuild redémarre chaque
        # service une fois, et une nuit d'`autoUpgrade` ne doit pas sonner.
        #
        # Volontairement SANS filtre sur le nom : le mode de panne vaut pour tout
        # ce qui porte une politique de redémarrage.
        ServiceRedemarreEnBoucle = {
          alert = "ServiceRedemarreEnBoucle";
          expr = "increase(node_systemd_service_restart_total[1h]) > 3";
          for = "10m";
          labels.severity = "warning";
          annotations.summary = "L'unité {{ $labels.name }} a redémarré {{ $value | printf \"%.0f\" }} fois en une heure : elle tourne, mais elle n'arrête pas de renaître.";
        };

        # LE PLAFOND QUI NE PRÉVIENT PAS. La table de suivi de connexions du
        # noyau a une taille finie ; une fois pleine, le noyau REFUSE les
        # nouvelles connexions et écrit une ligne dans son journal, mais rien ne
        # tombe en panne : les services tournent, les sondes locales passent, et
        # depuis l'extérieur les connexions échouent au hasard.
        #
        # Cette machine multiplie les sources de connexions suivies : le tunnel
        # Cloudflare, les pairs WireGuard, le NAT du VPN et le résolveur, chacun
        # avec ses flux UDP dont les entrées expirent lentement.
        #
        # SUR LE RAPPORT et non sur un nombre : la limite est calculée par le
        # noyau depuis la mémoire disponible, donc un seuil absolu serait faux
        # sur toute autre machine. La marge mesurée est de trois ordres de
        # grandeur — cette alerte est faite pour dormir.
        #
        # PAS D'ÉQUIVALENT POUR LES DESCRIPTEURS DE FICHIERS, et c'est vérifié :
        # `node_filefd_maximum` vaut ici la limite que systemd pose quand il n'y
        # en a pas (9,2 × 10¹⁸). Une règle sur ce rapport serait inerte.
        TableDeConnexionsPresquePleine = {
          alert = "TableDeConnexionsPresquePleine";
          expr = "node_nf_conntrack_entries / node_nf_conntrack_entries_limit * 100 > 80";
          for = "15m";
          labels.severity = "warning";
          annotations.summary = "Table de suivi des connexions occupée à {{ $value | printf \"%.0f\" }} % : au plafond, le noyau refusera les nouvelles connexions sans qu'aucun service ne tombe.";
        };

        # Pas un détail de confort sur CETTE machine : les codes TOTP d'Authelia
        # sont calculés sur l'heure, et une dérive suffisante les fait tous
        # refuser sans que rien n'explique pourquoi.
        HorlogeDerive = {
          alert = "HorlogeDerive";
          expr = "abs(node_timex_offset_seconds) > 0.05";
          for = "15m";
          labels.severity = "warning";
          annotations.summary = "Horloge décalée de {{ $value | printf \"%.3f\" }} s : les codes TOTP finiront par être refusés.";
        };

        # LA CHALEUR, QUI NE FAIT ÉCHOUER AUCUNE UNITÉ. C'est une dérive qui
        # s'installe sur des semaines — de la poussière, un ventilateur qui
        # ralentit, un été — jusqu'au jour où le processeur se bride ou où le
        # disque abrège sa vie.
        #
        # AU SEUIL DU CONSTRUCTEUR et non à un chiffre choisi au hasard :
        # `node_hwmon_temp_crit_celsius` est la limite que le matériel déclare
        # lui-même. Alerter à 90 % de cette valeur laisse une marge réelle sans
        # supposer quoi que ce soit d'un matériel qu'on ne connaît pas.
        #
        # LE `on(chip, sensor)` PORTE SUR LA COMPARAISON, pas sur la
        # multiplication : `0.9 * on(…) métrique` ne s'analyse pas, un
        # modificateur d'appariement ne pouvant pas s'appliquer entre un scalaire
        # et un vecteur. Écrit ainsi, PromQL rend un résultat vide sans erreur.
        #
        # Les capteurs sans limite déclarée sont ignorés d'eux-mêmes : la
        # jointure ne les apparie à rien.
        MachineTropChaude = {
          alert = "MachineTropChaude";
          expr = "node_hwmon_temp_celsius >= on(chip, sensor) (${seuilTemperature})";
          for = "15m";
          labels.severity = "warning";
          annotations.summary = "Capteur {{ $labels.chip }} à {{ $value | printf \"%.0f\" }} °C, soit 90 % de la limite constructeur : vérifie la poussière et les ventilateurs.";
        };

        # LE TIMER QUI CESSE DE SE DÉCLENCHER. Un timer qui ne se déclenche plus
        # n'échoue pas : pas d'unité en échec, pas de log, pas de métrique qui
        # bouge. Sur `nixos-upgrade`, ça veut dire que les correctifs de sécurité
        # ont cessé d'arriver ; sur `acme-renew-*`, que les certificats
        # expireront dans trente jours sans un mot.
        #
        # QUARANTE-HUIT HEURES pour des timers QUOTIDIENS : deux fois la période
        # laisse passer un décalage, un `Persistent` qui rattrape, ou une machine
        # éteinte une nuit — sans laisser filer une panne réelle.
        #
        # `> 0` N'EST PAS DÉCORATIF : un timer jamais déclenché depuis le
        # démarrage rapporte zéro, et `time() - 0` rendrait l'heure Unix
        # courante, soit cinquante-six ans de retard.
        TimerNeSeDeclenchePlus = {
          alert = "TimerNeSeDeclenchePlus";
          expr = "(time() - ${timersSurveilles} > ${toString seuils.timerSecondes}) and (node_systemd_timer_last_trigger_seconds > 0)";
          for = "1h";
          labels.severity = "critical";
          annotations.summary = "Le timer {{ $labels.name }} ne s'est pas déclenché depuis plus de ${
            toString (seuils.timerSecondes / 3600)
          } h : ce qu'il devait faire ne se fait plus, et rien d'autre ne le dirait.";
        };
      };

      panels = {
        processeur = mkStat {
          id = 1;
          title = "Processeur";
          unit = "percent";
          description = "Part de temps processeur non oisif, tous cœurs confondus, lissée sur 5 minutes.";
          expr = "100 * (1 - avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m])))";
          steps = steps "green" [
            70
            "orange"
            90
            "red"
          ];
        };

        ramUtilisee = mkStat {
          id = 2;
          title = "RAM utilisée";
          unit = "percent";
          description = "Calculé sur `MemAvailable`, donc sur ce qu'une application pourrait vraiment obtenir : le cache du noyau ne compte pas comme occupé.";
          expr = "100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)";
          steps = steps "green" [
            80
            "orange"
            90
            "red"
          ];
        };

        # « Stockage » et non « Racine » : le chiffre-clé s'adresse au coup
        # d'œil, pas à l'administrateur qui sait ce qu'est `/`. La précision
        # perdue est mince — la racine occupe le disque à un gigaoctet près, le
        # reste étant `/boot`, qui a son propre suivi dans la section Stockage.
        stockageUtilise = mkStat {
          id = 3;
          title = "Stockage utilisé";
          unit = "percent";
          description = "Occupation de la racine, qui est le disque à un gigaoctet près. `/boot` a son propre suivi dans la section Stockage.";
          expr = "100 * (1 - node_filesystem_avail_bytes{mountpoint=\"/\"} / node_filesystem_size_bytes{mountpoint=\"/\"})";
          steps = steps "green" [
            85
            "orange"
            95
            "red"
          ];
        };

        # DES PROPRIÉTÉS DE LA MACHINE, PAS DES SÉRIES TEMPORELLES : aucune des
        # trois ne bouge sur une machine physique. Un chiffre-clé est exactement
        # la forme qui convient à une valeur qu'on veut connaître sans la suivre.
        # Le compte de cœurs donne aussi la clé de lecture du panneau `Charge`,
        # qui est en pourcentage de cette capacité.
        #
        # LES TROIS ENSEMBLE DANS UNE SEULE BOÎTE, parce qu'une machine ne se
        # décrit pas par « 4 » ni par « 14 Gio » mais par les trois à la fois.
        #
        # AUCUN SEUIL, d'où l'unique palier : colorer un nombre de cœurs
        # laisserait croire qu'il existe une bonne et une mauvaise valeur.
        #
        # UNITÉS MÊLÉES, d'où la surcharge : le panneau est en octets pour la RAM
        # et le disque, et le compte de cœurs redevient un nombre nu. Sans elle,
        # Grafana annoncerait « 4 o ».
        materiel = mkStat {
          id = 5;
          title = "Matériel";
          unit = "bytes";
          description = "Ce que la machine EST, et non ce qu'elle fait : trois constantes, qui donnent l'échelle de lecture des quatre mesures voisines.";
          # Trois constantes : la courbe de fond ne tracerait que des droites
          # plates, sur trois échelles sans rapport.
          graph = false;
          targets = [
            {
              expr = coeurs;
              legend = "cœurs";
            }
            {
              expr = "node_memory_MemTotal_bytes";
              legend = "RAM";
            }
            {
              # La racine, qui est le disque à un gigaoctet près — `/boot` mis
              # à part.
              expr = "node_filesystem_size_bytes{mountpoint=\"/\"}";
              legend = "stockage";
            }
          ];
          overrides = [
            {
              matcher = byName "cœurs";
              properties = [
                {
                  id = "unit";
                  value = "short";
                }
              ];
            }
          ];
          steps = steps "text" [ ];
        };

        processeurParMode = mkTs {
          id = 10;
          title = "Processeur par mode";
          unit = "percentunit";
          description = "Où part le temps processeur. `iowait` qui domine veut dire que la machine attend le disque, pas qu'elle calcule ; `steal` n'existe que sur une machine virtuelle.";
          stack = true;
          fill = 30;
          targets = [
            {
              expr = "sum by (mode) (rate(node_cpu_seconds_total{mode!=\"idle\"}[5m])) / on() group_left ${coeurs}";
              legend = "{{ mode }}";
            }
          ];
        };

        ram = mkTs {
          id = 11;
          title = "RAM";
          unit = "bytes";
          description = "« utilisée » exclut le cache du noyau. Le swap qui monte est le signal : quelque chose ne tient plus en mémoire.";
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
        };

        # RAPPORTÉE AU NOMBRE DE CŒURS, donc en pourcentage de capacité. La
        # charge brute est un nombre sans échelle ; divisée par les cœurs,
        # 100 % veut dire « exactement saturé » et il n'y a plus de repère à
        # tracer, puisqu'il est devenu l'échelle elle-même.
        chargeProcesseur = mkTs {
          id = 13;
          title = "Charge processeur";
          unit = "percent";
          description = "Charge système rapportée au nombre de cœurs : 100 % veut dire exactement saturé. L'alerte `ChargeElevee` se lit à ${
            toString (seuils.chargeParCoeur * 100)
          } %.";
          # PAS de borne haute ici, contrairement aux autres pourcentages : la
          # charge peut légitimement dépasser 100 %, et c'est justement ce qu'on
          # vient voir.
          targets =
            map
              (n: {
                expr = "100 * node_load${toString n} / on() group_left ${coeurs}";
                legend = "${toString n} min";
              })
              [
                1
                5
                15
              ];
        };

        # Sur une heure glissante, parce que le compteur brut est cumulatif
        # depuis le démarrage : sa valeur ne dit rien, sa progression dit tout.
        processusTues = mkTs {
          id = 21;
          title = "Processus tués faute de mémoire";
          unit = "short";
          description = "Le noyau tue un processus quand il ne peut plus allouer. Une barre non nulle est toujours un incident, même si la machine a l'air d'aller bien depuis.";
          decimals = 0;
          targets = [
            {
              expr = "increase(node_vmstat_oom_kill_total[1h])";
              legend = "tués sur 1 h";
            }
          ];
        };

        # LA SATURATION, QUI EST UNE AUTRE QUESTION QUE L'USAGE. Les panneaux
        # voisins disent ce que la machine CONSOMME ; celui-ci dit ce qu'elle
        # ATTEND, c'est-à-dire la seule chose qui explique « c'est lent ».
        #
        # LA PRESSION (PSI) : la fraction de temps pendant laquelle au moins une
        # tâche est bloquée faute de processeur, de mémoire ou d'entrée-sortie.
        # C'est plus direct que la charge moyenne, qui compte les tâches prêtes
        # sans dire si elles souffrent.
        #
        # L'OCCUPATION DU DISQUE avec : un disque se sature sur des OPÉRATIONS,
        # pas sur un volume. Des milliers de petites écritures dispersées — les
        # miniatures de Nextcloud, PostgreSQL — le tiennent occupé à 100 % pour
        # un débit dérisoire, que le panneau `Disque` montre comme du repos.
        #
        # PAS DE BORNE HAUTE : la valeur normale est proche de ZÉRO et c'est le
        # pic qui porte l'information ; borner à 100 écraserait les courbes sur
        # l'axe.
        #
        # « ATTENTE » ET NON « SATURATION » dans le titre : un panneau intitulé
        # « Saturation » avec des pourcentages ne dit pas de QUOI ils sont le
        # pourcentage. Formulé en temps d'attente, il n'y a plus d'ambiguïté.
        tempsAttente = mkTs {
          id = 44;
          title = "Temps passé à attendre";
          unit = "percent";
          description = "Part du temps pendant laquelle quelque chose attend une ressource au lieu de travailler. 10 % sur la courbe processeur veut dire que pendant 10 % du temps, au moins une tâche voulait le processeur et ne l'a pas obtenu. Zéro est l'état normal. C'est ce qui explique « la machine est lente » quand tous les autres panneaux ont l'air calmes — le processeur peut être à 30 % pendant que tout attend le disque.";
          targets = [
            {
              expr = "rate(node_pressure_cpu_waiting_seconds_total[5m]) * 100";
              legend = "en attente du processeur";
            }
            {
              expr = "rate(node_pressure_io_waiting_seconds_total[5m]) * 100";
              legend = "en attente du disque";
            }
            {
              expr = "rate(node_pressure_memory_waiting_seconds_total[5m]) * 100";
              legend = "en attente de mémoire";
            }
            {
              # LA SEULE QUI NE MESURE PAS UNE ATTENTE : le temps où le DISQUE
              # travaille. Elle se lit avec les autres — un disque occupé à
              # 100 % explique une attente d'entrées-sorties —, et sa légende
              # dit qu'elle parle d'autre chose.
              expr = "rate(node_disk_io_time_seconds_total[5m]) * 100";
              legend = "disque {{ device }} occupé";
            }
          ];
        };

        reseau = mkTs {
          id = 14;
          title = "Réseau";
          unit = "Bps";
          description = "Débit par interface. L'émission est tracée SOUS l'axe pour lire les deux sens d'un coup d'œil : la valeur reste positive dans la légende et l'infobulle.";
          min = null;
          mirror = "↑ .*";
          targets = [
            {
              expr = "rate(node_network_receive_bytes_total{device!~\"lo|docker.*|veth.*\"}[5m])";
              legend = "↓ {{ device }}";
            }
            {
              expr = "rate(node_network_transmit_bytes_total{device!~\"lo|docker.*|veth.*\"}[5m])";
              legend = "↑ {{ device }}";
            }
          ];
        };

        disque = mkTs {
          id = 15;
          title = "Disque";
          unit = "Bps";
          description = "Débit par périphérique. L'écriture est tracée sous l'axe, comme l'émission du panneau réseau.";
          min = null;
          mirror = "écriture .*";
          targets = [
            {
              expr = "rate(node_disk_read_bytes_total[5m])";
              legend = "lecture {{ device }}";
            }
            {
              expr = "rate(node_disk_written_bytes_total[5m])";
              legend = "écriture {{ device }}";
            }
          ];
        };

        # Processeur, circuit graphique intégré et disque sur le même axe : ce
        # qui informe n'est pas la valeur absolue mais l'ÉCART entre elles et
        # leur dérive commune — une panne lente, invisible au jour le jour, que
        # les alertes `MachineTropChaude` et `DisqueTropChaud` n'attrapent
        # qu'une fois tard.
        #
        # La jointure sur `node_hwmon_chip_names` sert uniquement à la légende :
        # sans elle les séries s'appellent `pci0000:00_0000:00:18_3`.
        temperatures = mkTs {
          id = 30;
          title = "Températures";
          unit = "celsius";
          description = "Ce qui informe n'est pas la valeur absolue mais l'écart entre les courbes et leur dérive commune : trois qui montent ensemble sur des semaines, c'est de la poussière ou un ventilateur qui faiblit.";
          targets = [
            {
              expr = "node_hwmon_temp_celsius * on(chip) group_left(chip_name) node_hwmon_chip_names";
              legend = "{{ chip_name }}";
            }
            {
              expr = "smartctl_device_temperature{temperature_type=\"current\"}";
              legend = "disque {{ device }}";
            }
            {
              # Le seuil de `MachineTropChaude`, tracé avec la mesure.
              expr = seuilTemperature;
              legend = "seuil d'alerte";
            }
          ];
          overrides = [ (thresholdLine (byName "seuil d'alerte")) ];
        };

        # `min` nul et non zéro : la dérive va dans les deux sens, et un décalage
        # négatif est aussi fatal aux codes TOTP qu'un positif.
        deriveHorloge = mkTs {
          id = 22;
          title = "Dérive d'horloge";
          unit = "s";
          description = "Décalage que NTP est en train de corriger. Au-delà de 50 ms, les codes TOTP d'Authelia commencent à être refusés sans que rien n'explique pourquoi.";
          min = null;
          targets = [
            {
              expr = "node_timex_offset_seconds";
              legend = "décalage";
            }
          ];
        };

        # EN POURCENTAGE ET NON EN OCTETS : en valeur absolue, `/boot` est
        # plusieurs centaines de fois plus petit que `/`, et sa courbe restait
        # collée à l'axe — alors que c'est précisément la partition qui se
        # remplit toute seule. Le pourcentage est aussi la bonne grandeur pour
        # « est-ce que ça se remplit », et les seuils des alertes s'y lisent
        # directement.
        espaceDisqueLibre = mkTs {
          id = 12;
          title = "Espace disque libre";
          unit = "percent";
          description = "En pourcentage, ce qui rend `/` et `/boot` comparables malgré un rapport de 370 entre leurs tailles — et fait lire directement les seuils des alertes, écrits en pourcentage eux aussi.";
          # BORNÉ À 100 : une racine stable entre 38,4 et 38,6 % se lirait sinon
          # comme une montagne russe.
          max = 100;
          targets = [
            {
              expr = "100 * node_filesystem_avail_bytes{${fsSelector}} / node_filesystem_size_bytes{${fsSelector}}";
              legend = "{{ mountpoint }}";
            }
          ];
        };

        # L'autre façon de remplir un disque, et la plus déroutante : `df`
        # annonce de la place libre pendant que toute écriture échoue.
        inodesLibres = mkTs {
          id = 23;
          title = "Inodes libres";
          unit = "short";
          description = "L'autre façon de remplir un disque : `df` annonce de la place pendant que toute écriture échoue. À rapprocher du panneau « Nextcloud : fichiers », qui en est le producteur.";
          targets = [
            {
              expr = "node_filesystem_files_free{${fsSelector}}";
              legend = "{{ mountpoint }}";
            }
          ];
        };

        # Une SÉRIE PAR UNITÉ, pas un compteur : le nom de l'unité est
        # précisément l'information que l'alerte ne transporte pas, et la forme
        # de la courbe distingue une panne franche d'un clignotement.
        unitesEnEchec = mkTs {
          id = 19;
          title = "Unités systemd en échec";
          unit = "short";
          description = "Une série par unité tombée, avec son nom — l'information que l'alerte Discord ne transporte pas. « aucune en échec » à zéro est l'état normal, et dit que la collecte fonctionne.";
          decimals = 0;
          targets = [
            {
              # LE NOM DE L'UNITÉ **ET** PAS DE « No Data ».
              #
              # `… {state="failed"} == 1` ne rend RIEN quand tout va bien, et
              # Grafana écrit « No Data » — qui dit aussi bien « aucune unité en
              # échec » que « la collecte est morte ». Un `count(…) or vector(0)`
              # réglerait l'ambiguïté mais perdrait le nom.
              #
              # D'où `absent()`, qui ne rend une valeur QUE lorsque son argument
              # n'en rend aucune. Multiplié par zéro et étiqueté par
              # `label_replace`, il fabrique une série de repli qui porte un nom
              # lisible — et qui DISPARAÎT dès qu'une vraie unité tombe.
              #
              # À NE PAS GÉNÉRALISER : ce repli vaut pour un COMPTE D'ÉVÉNEMENTS,
              # où zéro veut dire « rien ne s'est produit ». Sur une jauge d'état
              # il mentirait — un 0 sur une usure de disque absente afficherait
              # « disque neuf » là où la vérité est « pas mesurable ».
              expr = "(node_systemd_unit_state{state=\"failed\"} == 1) or label_replace(absent(node_systemd_unit_state{state=\"failed\"} == 1) * 0, \"name\", \"aucune en échec\", \"\", \"\")";
              legend = "{{ name }}";
            }
          ];
        };

        # LE JUMEAU DU PANNEAU VOISIN : celui-ci voit ce qui n'atteint jamais
        # l'état `failed`, comme la règle `ServiceRedemarreEnBoucle`.
        #
        # LE FILTRE `> 0` N'EST PAS COSMÉTIQUE : la métrique existe pour chaque
        # unité de la machine, et sans lui le panneau empile des centaines de
        # séries plates à zéro. Le repli par `absent()` est le même procédé que
        # chez le voisin.
        servicesQuiRedemarrent = mkTs {
          id = 40;
          title = "Services qui redémarrent";
          unit = "short";
          description = "Redémarrages par unité sur l'heure écoulée. Un service peut renaître indéfiniment sans jamais passer en échec : c'est la seule vue de ce mode de panne. L'alerte se déclenche au-delà de trois.";
          decimals = 0;
          targets = [
            {
              expr = "(increase(node_systemd_service_restart_total[1h]) > 0) or label_replace(absent(increase(node_systemd_service_restart_total[1h]) > 0) * 0, \"name\", \"aucun redémarrage\", \"\", \"\")";
              legend = "{{ name }}";
            }
          ];
        };

        # LA COURBE DIT CE QUE `TimerNeSeDeclenchePlus` NE DIT PAS : un timer
        # sain dessine un escalier, l'âge monte jusqu'à vingt-quatre heures puis
        # retombe à zéro. Un timer mort est une droite qui monte et ne redescend
        # plus — ce qui se voit avant les quarante-huit heures du seuil.
        #
        # Le `and (… > 0)` est le même garde-fou que dans la règle.
        timers = mkTs {
          id = 42;
          title = "Timers : temps depuis le dernier déclenchement";
          unit = "s";
          description = "Un escalier qui retombe chaque nuit est le comportement sain. Une droite qui monte sans redescendre veut dire qu'un timer ne se déclenche plus — ce qui ne fait échouer aucune unité et ne produit aucun journal.";
          h = 6;
          targets = [
            {
              expr = "(time() - ${timersSurveilles}) and (node_systemd_timer_last_trigger_seconds > 0)";
              legend = "{{ name }}";
            }
            {
              expr = toString seuils.timerSecondes;
              legend = "seuil d'alerte";
            }
          ];
          overrides = [ (thresholdLine (byName "seuil d'alerte")) ];
        };
      };
    };
  };
}
