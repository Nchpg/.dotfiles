{
  config,
  lib,
  myLib,
  ...
}:

# SANTÉ PHYSIQUE DES DISQUES (`disks.enable`). Seul composant dont les alertes
# annoncent une perte de DONNÉES et non une interruption de service : tout le
# reste se répare en redémarrant quelque chose.
#
# Il double `smartd`, déjà actif (cf. modules/system/storage/disks), sans faire
# doublon : smartd n'a que `systembus-notify` comme canal, c'est-à-dire une
# notification de bureau sur une machine qui n'a aucune session graphique. Il
# détecte, et personne ne l'entend.
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
        # L'exporteur ne réinterroge de toute façon pas les disques plus d'une
        # fois par minute (`maxInterval`), et une lecture SMART n'est pas
        # gratuite : la collecter toutes les trente secondes ne ferait que
        # dupliquer la même valeur.
        scrape_interval = "1m";
      };

      # Tous les noms de métriques ci-dessous ont été relevés dans le binaire de
      # l'exporteur, pas devinés — une règle qui vise une métrique inexistante
      # ne fait jamais échouer quoi que ce soit, elle ne protège simplement de
      # rien, en silence.
      #
      # ET CE N'EST PAS SUFFISANT : exister dans le binaire ne veut pas dire être
      # publié pour LE disque qu'on a. `percentage_used`, `available_spare`,
      # `critical_warning` et `media_errors` viennent du health log NVMe et ne
      # sortent QUE pour un NVMe. Sur le SATA de cette machine, elles sont
      # inertes — d'où les équivalents ATA plus bas.
      #
      # Les deux familles cohabitent volontairement : les règles NVMe restent
      # inoffensives sur un SATA (leur métrique est absente, elles ne s'évaluent
      # sur rien) et redeviennent utiles le jour où un NVMe est branché.
      #
      # Côté ATA, le sélecteur porte sur `attribute_id` et NON sur
      # `attribute_name` : les identifiants sont à peu près standards, les noms
      # sont inventés par chaque constructeur — ce disque annonce
      # `Reallocate_NAND_Blk_Cnt` là où la littérature dit
      # `Reallocated_Sector_Ct`.
      alertRules = {
        # Le verdict d'ensemble du disque : 0 signifie qu'il s'annonce lui-même
        # comme défaillant. Sur un NVMe, ça n'arrive pas avant que plusieurs
        # indicateurs soient déjà partis.
        DisqueSmartEnEchec = {
          alert = "DisqueSmartEnEchec";
          expr = "smartctl_device_smart_status == 0";
          for = "5m";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.device }} se déclare défaillant (SMART). Sauvegarde ce qui compte AVANT de chercher à comprendre.";
        };

        # Bits d'avertissement du contrôleur NVMe : réserve épuisée, température
        # hors plage, média en lecture seule, sauvegarde volatile perdue.
        # N'importe lequel mérite qu'on regarde tout de suite.
        DisqueAvertissementCritique = {
          alert = "DisqueAvertissementCritique";
          expr = "smartctl_device_critical_warning > 0";
          for = "5m";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.device }} lève un avertissement critique NVMe (code {{ $value }}).";
        };

        # Blocs de secours sous le seuil que le CONSTRUCTEUR a lui-même fixé,
        # plutôt qu'un pourcentage choisi au hasard : le disque sait mieux que
        # nous à partir de quand il n'a plus de marge.
        DisqueReserveEpuisee = {
          alert = "DisqueReserveEpuisee";
          expr = "smartctl_device_available_spare < smartctl_device_available_spare_threshold";
          for = "15m";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.device }} : blocs de secours sous le seuil constructeur, la fin est proche.";
        };

        # Erreurs de média NON CORRIGÉES : chacune est une donnée que le disque
        # n'a pas pu relire. Sans `for`, parce qu'il n'y a rien à confirmer —
        # c'est déjà arrivé.
        DisqueErreursDeMedia = {
          alert = "DisqueErreursDeMedia";
          expr = "increase(smartctl_device_media_errors[24h]) > 0";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.device }} : {{ $value | printf \"%.0f\" }} erreur(s) de média non corrigée(s) en 24 h.";
        };

        # Usure d'écriture, en pourcentage de l'endurance prévue. À 85 % le
        # disque fonctionne encore parfaitement : c'est une alerte pour
        # COMMANDER un remplaçant, pas pour intervenir dans l'heure.
        DisqueUsureElevee = {
          alert = "DisqueUsureElevee";
          expr = "smartctl_device_percentage_used > 85";
          for = "1h";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.device }} a consommé {{ $value | printf \"%.0f\" }} % de son endurance d'écriture.";
        };

        # --- Équivalents ATA/SATA des règles NVMe ci-dessus ------------------

        # Attribut 202, pendant exact de `percentage_used` : la valeur BRUTE est
        # le pourcentage CONSOMMÉ, la valeur normalisée étant son complément.
        # Sémantique Crucial/Micron, qui est ce qui est branché ; un autre
        # constructeur peut loger autre chose sous 202, à revérifier au
        # changement de disque.
        DisqueUsureEleveeAta = {
          alert = "DisqueUsureElevee";
          expr = "smartctl_device_attribute{attribute_id=\"202\",attribute_value_type=\"raw\"} > 85";
          for = "1h";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.device }} a consommé {{ $value | printf \"%.0f\" }} % de son endurance d'écriture.";
        };

        # Secteurs définitivement NON RELUS : 187 remontés au système, 198
        # découverts par l'analyse hors ligne. L'équivalent ATA de
        # `media_errors`. Ces deux-là ne font que MONTER, donc le seuil est zéro
        # et un `for` court suffit.
        DisqueSecteursIllisibles = {
          alert = "DisqueSecteursIllisibles";
          expr = "smartctl_device_attribute{attribute_id=~\"187|198\",attribute_value_type=\"raw\"} > 0";
          for = "5m";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.device }} : {{ $value | printf \"%.0f\" }} secteur(s) illisible(s) (attribut {{ $labels.attribute_id }}).";
        };

        # Secteurs EN ATTENTE de relecture (197), séparés des deux précédents
        # parce que ce compteur monte ET redescend : le disque retire un secteur
        # de la liste dès qu'il parvient à le réécrire. Sur ce disque il oscille
        # entre 0 et 1.
        #
        # D'où le `for` d'une heure : un secteur récupéré disparaît en quelques
        # minutes, un secteur réellement mort reste en attente indéfiniment. À 5
        # minutes cette règle sonnerait sur du bruit.
        DisqueSecteursEnAttente = {
          alert = "DisqueSecteursEnAttente";
          expr = "smartctl_device_attribute{attribute_id=\"197\",attribute_value_type=\"raw\"} > 0";
          for = "1h";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.device }} : {{ $value | printf \"%.0f\" }} secteur(s) en attente depuis plus d'une heure, donc non récupérable(s).";
        };

        # Blocs réalloués, sur leur PROGRESSION et non leur valeur absolue : un
        # disque de remplacement peut arriver avec un compteur non nul d'usine,
        # alors qu'une réallocation qui CONTINUE est le signe que la NAND lâche.
        DisqueBlocsRealloues = {
          alert = "DisqueBlocsRealloues";
          expr = "increase(smartctl_device_attribute{attribute_id=\"5\",attribute_value_type=\"raw\"}[24h]) > 0";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.device }} a réalloué {{ $value | printf \"%.0f\" }} bloc(s) en 24 h : commander un remplaçant.";
        };

        # LA TEMPÉRATURE DU DISQUE, qui n'a pas de seuil constructeur exposé
        # contrairement aux capteurs de la carte — d'où un chiffre écrit ici.
        #
        # 55 °C sur une plage de fonctionnement de 0 à 70 pour un SSD SATA grand
        # public : quinze degrés de marge avant la limite. Au-delà de 70,
        # l'électronique se bride et l'endurance de la NAND chute — sans que
        # rien ne tombe en panne. À revoir si un NVMe le remplace : ils chauffent
        # nettement plus et tolèrent davantage.
        #
        # `temperature_type="current"` N'EST PAS REDONDANT : l'exporteur sort
        # aussi `drive_trip` — la température à laquelle le disque se coupe —
        # quand le matériel la déclare, ce que font les NVMe. Sans le filtre,
        # brancher un NVMe allumerait cette alerte en permanence sur une
        # CONSTANTE.
        DisqueTropChaud = {
          alert = "DisqueTropChaud";
          expr = "smartctl_device_temperature{temperature_type=\"current\"} > 55";
          for = "15m";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.device }} à {{ $value | printf \"%.0f\" }} °C : au-delà de 70 il se bride et son endurance chute, sans jamais tomber en panne.";
        };

        # Erreurs CRC de la LIAISON SATA (attribut 199), pas du média : c'est le
        # câble, le connecteur ou l'alimentation. Les données sont retransmises,
        # donc rien n'est perdu — mais un lien qui se dégrade finit par faire
        # tomber le disque du bus, ce qui, sur une machine à disque unique,
        # arrête tout.
        #
        # Sur la PROGRESSION, impérativement : le compteur est cumulatif depuis
        # la sortie d'usine et vaut déjà plusieurs milliers ici, hérité d'un
        # câblage antérieur.
        #
        # Une perte de lien franche ne déplace PAS ce compteur : c'est la règle
        # `DisqueErreurAtaNoyau` de Loki (components/logs.nix) qui la voit.
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
          # Même grandeur, autre bus : les deux séries NVMe ci-dessus sont vides
          # sur un SATA, celle-ci l'est sur un NVMe.
          #
          # Pas de série « réserve » côté ATA : l'attribut 180 l'expose en NOMBRE
          # DE BLOCS, qui n'a rien à faire dans un panneau en pourcentage.
          {
            expr = "smartctl_device_attribute{attribute_id=\"202\",attribute_value_type=\"raw\"}";
            legend = "usure {{ device }}";
          }
        ];
      };
    };
  };
}
