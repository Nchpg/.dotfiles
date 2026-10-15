{
  config,
  lib,
  ...
}:

# Alertmanager : regroupe, dédoublonne, et pousse vers Discord.
let
  cfg = config.systemSettings.monitoring;
  notify = config.systemSettings.notify.discord;
  inherit (cfg.internal) ports alertRules;

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

  # SEUILS EMBOÎTÉS : les couples de règles qui décrivent le MÊME symptôme à deux
  # hauteurs, déclarés par l'attribut `inhibits` de la règle critique. La
  # critique déclenche toujours l'autre avec elle — un disque à 96 % dépasse
  # aussi 85 % — donc sans inhibition, deux messages partent pour un seul
  # problème, dont un qui le minimise.
  #
  # POURQUOI DES PAIRES NOMMÉES plutôt que l'exemple canonique de la
  # documentation d'Alertmanager :
  #
  #   source severity="critical" → target severity="warning", equal = [ alertname, instance ]
  #
  # Cet exemple suppose qu'une MÊME règle émette tantôt `warning` tantôt
  # `critical`, en portant la gravité dans une étiquette calculée. Ici, chaque
  # règle a un nom ET une gravité fixes : aucune paire d'alertes ne partage un
  # `alertname` avec deux gravités différentes, la condition `equal` ne pourrait
  # jamais être satisfaite et l'inhibition ne s'appliquerait jamais.
  #
  # `equal` porte sur ce qui identifie l'OBJET, pas sur l'alerte : deux points de
  # montage qui se remplissent en même temps doivent rester deux alertes.
  seuilsEmboites = lib.concatMap (
    r:
    lib.optional (r ? inhibits) {
      critique = r.alert;
      avertissement = r.inhibits.alertname;
      inherit (r.inhibits) equal;
    }
  ) (lib.attrValues alertRules);

  nomsDeRegles = map (r: r.alert) (lib.attrValues alertRules);
  inhibitionsOrphelines = lib.filter (p: !(lib.elem p.avertissement nomsDeRegles)) seuilsEmboites;
in
{
  config = lib.mkIf cfg.enable {
    # Une inhibition qui vise une alerte inexistante (renommée, retirée) ne
    # casse rien : elle n'inhibe plus, et le doublon repart sur Discord.
    assertions = [
      {
        assertion = inhibitionsOrphelines == [ ];
        message = "systemSettings.monitoring : `inhibits` vise une alerte qui n'existe pas : ${
          toString (map (p: "${p.critique} -> ${p.avertissement}") inhibitionsOrphelines)
        }";
      }
    ];

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
          # tout (cf. components/meta.nix). Une route sans sa règle serait
          # morte ; une règle sans sa route, pire — l'alerte perpétuelle
          # retomberait sur le receveur par défaut et partirait sur Discord
          # toutes les cinq minutes, indéfiniment.
          routes = lib.optional cfg.deadManSwitch.enable {
            receiver = "deadman";
            matchers = [ ''alertname="Watchdog"'' ];
            group_wait = "0s";
            group_interval = "1m";
            repeat_interval = cfg.deadManSwitch.interval;
          };
        };

        inhibit_rules = map (p: {
          source_matchers = [ ''alertname="${p.critique}"'' ];
          target_matchers = [ ''alertname="${p.avertissement}"'' ];
          inherit (p) equal;
        }) seuilsEmboites;

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
        # route : les trois apparaissent ensemble ou aucune.
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

    # Se surveiller lui-même a un sens précis ici : c'est de ses métriques que
    # vient `AlertmanagerNEnvoiePlus`.
    systemSettings.monitoring.internal.scrapeJobs.alertmanager =
      cfg.internal.helpers.localJob "alertmanager" ports.alertmanager;

    # Le webhook est DÉJÀ déclaré par modules/system/notify, mais on le redéclare
    # ici : ce module doit fonctionner même si le signalement d'échec d'unité est
    # coupé, et c'est cette déclaration-là qui fait entrer alertmanager dans
    # l'audience du secret (cf. lib/sops/policy.nix). Les deux définitions
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

    systemd.services.alertmanager.serviceConfig.LoadCredential = [
      "discord_webhook:${config.sops.secrets.${notify.webhookKey}.path}"
    ]
    ++ lib.optional cfg.deadManSwitch.enable "healthchecks_ping:${
      config.sops.secrets.${cfg.deadManSwitch.pingUrlKey}.path
    }";

    # Alertmanager arrêté ne route plus l'alerte qui le dirait : le signalement
    # d'échec d'unité est son SEUL filet.
    systemSettings.notify.discord.units = [ "alertmanager" ];
  };
}
