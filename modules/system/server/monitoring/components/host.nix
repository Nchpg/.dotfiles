{
  config,
  lib,
  myLib,
  ...
}:

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

  seuils = {
    chargeParCoeur = 2;
    timerSecondes = 48 * 3600;
  };

  # Scalaire sans étiquette : le diviser à une série étiquetée demande `on() group_left`.
  coeurs = ''count without(cpu, mode) (node_cpu_seconds_total{mode="idle"})'';

  # `/nix/store` exclu : montage lié de la racine, les alertes partiraient en double.
  fsSelector = ''fstype!~"tmpfs|ramfs|overlay|nsfs|squashfs|fuse.*",mountpoint!="/nix/store"'';

  # Timers quotidiens seulement : les hebdomadaires demanderaient un autre seuil.
  timersSurveilles = ''node_systemd_timer_last_trigger_seconds{name=~"nixos-upgrade.timer|acme-.+"}'';

  seuilTemperature = "0.9 * node_hwmon_temp_crit_celsius";
in
{
  config = lib.mkIf cfg.enable {
    services.prometheus.exporters.node = helpers.mkLocalExporter ports.node // {
      enabledCollectors = [ "systemd" ];

      extraFlags = [ "--collector.systemd.enable-restarts-metrics" ];
    };

    systemSettings.notify.discord.units = [ "prometheus-node-exporter" ];

    systemSettings.monitoring.internal = {
      scrapeJobs.node = helpers.localJob "node" ports.node // {
        # `/proc/vmstat` ignore la convention du suffixe.
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
          inhibits = {
            alertname = "DisqueBientotPlein";
            equal = [
              "instance"
              "mountpoint"
            ];
          };
        };

        # Le second terme évite qu'un disque à 4 % qui gagne un mégaoctet déclenche l'alerte.
        DisquePleinEnTroisJours = {
          alert = "DisquePleinEnTroisJours";
          expr = "predict_linear(node_filesystem_avail_bytes{${fsSelector}}[6h], 3 * 24 * 3600) < 0 and node_filesystem_avail_bytes{${fsSelector}} / node_filesystem_size_bytes{${fsSelector}} < 0.4";
          for = "1h";
          labels.severity = "warning";
          annotations.summary = "Au rythme actuel, {{ $labels.mountpoint }} sera plein d'ici trois jours.";
        };

        InodesEpuises = {
          alert = "InodesEpuises";
          expr = "node_filesystem_files_free{${fsSelector}} / node_filesystem_files{${fsSelector}} * 100 < 10";
          for = "30m";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.mountpoint }} : plus que {{ $value | printf \"%.1f\" }} % d'inodes libres.";
        };

        SystemeDeFichiersEnLectureSeule = {
          alert = "SystemeDeFichiersEnLectureSeule";
          expr = "node_filesystem_readonly{${fsSelector}} == 1";
          for = "5m";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.mountpoint }} est passé en lecture seule.";
        };

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

        ProcessusTuePourMemoire = {
          alert = "ProcessusTuePourMemoire";
          expr = "increase(node_vmstat_oom_kill_total[15m]) > 0";
          labels.severity = "critical";
          annotations.summary = "Le noyau a tué au moins un processus faute de mémoire.";
        };

        ChargeElevee = {
          alert = "ChargeElevee";
          expr = "node_load15 > ${toString seuils.chargeParCoeur} * ${coeurs}";
          for = "30m";
          labels.severity = "warning";
          annotations.summary = "Charge sur 15 minutes à {{ $value | printf \"%.1f\" }}, soit plus du double des cœurs disponibles.";
        };

        UniteSystemdEnEchec = {
          alert = "UniteSystemdEnEchec";
          expr = "node_systemd_unit_state{state=\"failed\"} == 1";
          for = "10m";
          labels.severity = "warning";
          annotations.summary = "L'unité {{ $labels.name }} est en échec.";
        };

        # Seuil à trois par heure : un rebuild redémarre chaque service une fois.
        ServiceRedemarreEnBoucle = {
          alert = "ServiceRedemarreEnBoucle";
          expr = "increase(node_systemd_service_restart_total[1h]) > 3";
          for = "10m";
          labels.severity = "warning";
          annotations.summary = "L'unité {{ $labels.name }} a redémarré {{ $value | printf \"%.0f\" }} fois en une heure : elle tourne, mais elle n'arrête pas de renaître.";
        };

        # Pas d'équivalent pour les descripteurs de fichiers : `node_filefd_maximum` vaut 9,2 × 10¹⁸ ici.
        TableDeConnexionsPresquePleine = {
          alert = "TableDeConnexionsPresquePleine";
          expr = "node_nf_conntrack_entries / node_nf_conntrack_entries_limit * 100 > 80";
          for = "15m";
          labels.severity = "warning";
          annotations.summary = "Table de suivi des connexions occupée à {{ $value | printf \"%.0f\" }} % : au plafond, le noyau refusera les nouvelles connexions sans qu'aucun service ne tombe.";
        };

        HorlogeDerive = {
          alert = "HorlogeDerive";
          expr = "abs(node_timex_offset_seconds) > 0.05";
          for = "15m";
          labels.severity = "warning";
          annotations.summary = "Horloge décalée de {{ $value | printf \"%.3f\" }} s : les codes TOTP finiront par être refusés.";
        };

        # Le `on(chip, sensor)` porte sur la comparaison : `0.9 * on(…) métrique` ne s'analyse pas.
        MachineTropChaude = {
          alert = "MachineTropChaude";
          expr = "node_hwmon_temp_celsius >= on(chip, sensor) (${seuilTemperature})";
          for = "15m";
          labels.severity = "warning";
          annotations.summary = "Capteur {{ $labels.chip }} à {{ $value | printf \"%.0f\" }} °C, soit 90 % de la limite constructeur : vérifie la poussière et les ventilateurs.";
        };

        # `> 0` : un timer jamais déclenché rapporte 0 et `time() - 0` ferait cinquante-six ans.
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

        # Unités mêlées d'où la surcharge, sinon Grafana annoncerait « 4 o ».
        materiel = mkStat {
          id = 5;
          title = "Matériel";
          unit = "bytes";
          description = "Ce que la machine EST, et non ce qu'elle fait : trois constantes, qui donnent l'échelle de lecture des quatre mesures voisines.";
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

        chargeProcesseur = mkTs {
          id = 13;
          title = "Charge processeur";
          unit = "percent";
          description = "Charge système rapportée au nombre de cœurs : 100 % veut dire exactement saturé. L'alerte `ChargeElevee` se lit à ${
            toString (seuils.chargeParCoeur * 100)
          } %.";
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

        # Pas de borne haute (normal proche de zéro, le pic informe).
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

        # La jointure sur `node_hwmon_chip_names` ne sert qu'à la légende.
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
              expr = seuilTemperature;
              legend = "seuil d'alerte";
            }
          ];
          overrides = [ (thresholdLine (byName "seuil d'alerte")) ];
        };

        # `min` nul : la dérive va dans les deux sens.
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

        espaceDisqueLibre = mkTs {
          id = 12;
          title = "Espace disque libre";
          unit = "percent";
          description = "En pourcentage, ce qui rend `/` et `/boot` comparables malgré un rapport de 370 entre leurs tailles — et fait lire directement les seuils des alertes, écrits en pourcentage eux aussi.";
          max = 100;
          targets = [
            {
              expr = "100 * node_filesystem_avail_bytes{${fsSelector}} / node_filesystem_size_bytes{${fsSelector}}";
              legend = "{{ mountpoint }}";
            }
          ];
        };

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

        unitesEnEchec = mkTs {
          id = 19;
          title = "Unités systemd en échec";
          unit = "short";
          description = "Une série par unité tombée, avec son nom — l'information que l'alerte Discord ne transporte pas. « aucune en échec » à zéro est l'état normal, et dit que la collecte fonctionne.";
          decimals = 0;
          targets = [
            {
              # `absent()` fabrique une série de repli nommée, pour éviter « No Data ». Faux pour une jauge d'état.
              expr = "(node_systemd_unit_state{state=\"failed\"} == 1) or label_replace(absent(node_systemd_unit_state{state=\"failed\"} == 1) * 0, \"name\", \"aucune en échec\", \"\", \"\")";
              legend = "{{ name }}";
            }
          ];
        };

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
