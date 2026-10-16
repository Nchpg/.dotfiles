{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.systemSettings.monitoring;
  inherit (cfg.internal) ports helpers;
  inherit (myLib.server.grafana) mkTs;
in
{
  config = lib.mkIf (cfg.enable && cfg.disks.enable) {
    services.prometheus.exporters.smartctl = helpers.mkLocalExporter ports.smartctl // {
      inherit (cfg.disks) devices;
    };

    systemSettings.notify.discord.units = [ "prometheus-smartctl-exporter" ];

    systemSettings.monitoring.internal = {
      scrapeJobs.smartctl = helpers.localJob "smartctl" ports.smartctl // {
        # L'exporteur ne réinterroge pas les disques plus d'une fois par minute.
        scrape_interval = "1m";
      };

      # Les métriques NVMe sont inertes sur SATA, d'où les équivalents ATA, sélectionnés par
      # `attribute_id` (les noms sont propres à chaque constructeur).
      alertRules = {
        DisqueSmartEnEchec = {
          alert = "DisqueSmartEnEchec";
          expr = "smartctl_device_smart_status == 0";
          for = "5m";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.device }} se déclare défaillant (SMART). Sauvegarde ce qui compte AVANT de chercher à comprendre.";
        };

        DisqueAvertissementCritique = {
          alert = "DisqueAvertissementCritique";
          expr = "smartctl_device_critical_warning > 0";
          for = "5m";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.device }} lève un avertissement critique NVMe (code {{ $value }}).";
        };

        DisqueReserveEpuisee = {
          alert = "DisqueReserveEpuisee";
          expr = "smartctl_device_available_spare < smartctl_device_available_spare_threshold";
          for = "15m";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.device }} : blocs de secours sous le seuil constructeur, la fin est proche.";
        };

        # Pas de `for` : des données non relues, rien à confirmer.
        DisqueErreursDeMedia = {
          alert = "DisqueErreursDeMedia";
          expr = "increase(smartctl_device_media_errors[24h]) > 0";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.device }} : {{ $value | printf \"%.0f\" }} erreur(s) de média non corrigée(s) en 24 h.";
        };

        DisqueUsureElevee = {
          alert = "DisqueUsureElevee";
          expr = "smartctl_device_percentage_used > 85";
          for = "1h";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.device }} a consommé {{ $value | printf \"%.0f\" }} % de son endurance d'écriture.";
        };

        # Attribut 202 : valeur brute = pourcentage consommé (sémantique Crucial/Micron).
        DisqueUsureEleveeAta = {
          alert = "DisqueUsureElevee";
          expr = "smartctl_device_attribute{attribute_id=\"202\",attribute_value_type=\"raw\"} > 85";
          for = "1h";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.device }} a consommé {{ $value | printf \"%.0f\" }} % de son endurance d'écriture.";
        };

        DisqueSecteursIllisibles = {
          alert = "DisqueSecteursIllisibles";
          expr = "smartctl_device_attribute{attribute_id=~\"187|198\",attribute_value_type=\"raw\"} > 0";
          for = "5m";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.device }} : {{ $value | printf \"%.0f\" }} secteur(s) illisible(s) (attribut {{ $labels.attribute_id }}).";
        };

        # `for` d'une heure : un secteur récupéré disparaît en minutes, un secteur mort reste en attente.
        DisqueSecteursEnAttente = {
          alert = "DisqueSecteursEnAttente";
          expr = "smartctl_device_attribute{attribute_id=\"197\",attribute_value_type=\"raw\"} > 0";
          for = "1h";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.device }} : {{ $value | printf \"%.0f\" }} secteur(s) en attente depuis plus d'une heure, donc non récupérable(s).";
        };

        # Sur la progression : un disque de remplacement peut arriver avec un compteur non nul.
        DisqueBlocsRealloues = {
          alert = "DisqueBlocsRealloues";
          expr = "increase(smartctl_device_attribute{attribute_id=\"5\",attribute_value_type=\"raw\"}[24h]) > 0";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.device }} a réalloué {{ $value | printf \"%.0f\" }} bloc(s) en 24 h : commander un remplaçant.";
        };

        # 55 °C faute de seuil constructeur ; `current` écarte `drive_trip` (température de coupure).
        DisqueTropChaud = {
          alert = "DisqueTropChaud";
          expr = "smartctl_device_temperature{temperature_type=\"current\"} > 55";
          for = "15m";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.device }} à {{ $value | printf \"%.0f\" }} °C : au-delà de 70 il se bride et son endurance chute, sans jamais tomber en panne.";
        };

        # Sur la progression : le compteur est cumulatif et vaut déjà plusieurs milliers.
        DisqueLiaisonSataDegradee = {
          alert = "DisqueLiaisonSataDegradee";
          expr = "increase(smartctl_device_attribute{attribute_id=\"199\",attribute_value_type=\"raw\"}[24h]) > 0";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.device }} : {{ $value | printf \"%.0f\" }} erreur(s) CRC sur la liaison SATA en 24 h. Câble ou connecteur, pas le disque.";
        };
      };

      panels.disquesUsure = mkTs {
        id = 18;
        title = "Disques : usure et réserve";
        unit = "percent";
        description = "Endurance d'écriture consommée et blocs de secours restants. Les séries NVMe et ATA cohabitent : celles qui ne correspondent pas au disque branché sont simplement absentes.";
        max = 100;
        targets = [
          {
            expr = "smartctl_device_percentage_used";
            legend = "usure {{ device }}";
          }
          {
            expr = "smartctl_device_available_spare";
            legend = "réserve {{ device }}";
          }
          {
            expr = "smartctl_device_attribute{attribute_id=\"202\",attribute_value_type=\"raw\"}";
            legend = "usure {{ device }}";
          }
        ];
      };
    };
  };
}
