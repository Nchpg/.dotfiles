{
  config,
  lib,
  myLib,
  pkgs-stable,
  target,
  ...
}:

let
  cfg = config.systemSettings.monitoring;
  inherit (cfg.internal) panels q;
  inherit (myLib.server.grafana) lokiDs promDs placeSections;

  squelette = [
    {
      title = "Vue d'ensemble";
      bands = [
        [
          "alertesEnCours"
          "processeur"
          "ramUtilisee"
          "stockageUtilise"
          "sondesEnEchec"
          "demarreDepuis"
          "materiel"
        ]
      ];
    }
    {
      title = "Machine";
      bands = [
        [
          "processeurParMode"
          "ram"
        ]
        [
          "chargeProcesseur"
          "processusTues"
        ]
        [ "tempsAttente" ]
        [
          "reseau"
          "disque"
        ]
        [
          "temperatures"
          "deriveHorloge"
        ]
      ];
    }
    {
      title = "Stockage";
      bands = [
        [
          "espaceDisqueLibre"
          "inodesLibres"
        ]
        [ "disquesUsure" ]
      ];
    }
    {
      title = "Accès public";
      bands = [
        [
          "sondesTempsDeReponse"
          "certificats"
        ]
        [ "tunnelCloudflare" ]
      ];
    }
    {
      title = "Services";
      bands = [
        [
          "nginx"
          "phpFpm"
        ]
        [
          "authelia"
          "wireguard"
        ]
        [
          "basesDeDonnees"
          "dnsmasq"
        ]
        [
          "coffre"
          "ssh"
        ]
        [
          "nextcloudComptes"
          "nextcloudFichiers"
        ]
        [
          "nextcloudStockage"
          "nextcloudBase"
        ]
      ];
    }
    {
      title = "Journaux";
      bands = [
        [ "journalParGravite" ]
        [ "journalErreurs" ]
      ];
    }
    {
      title = "Surveillance";

      collapsed = false;
      bands = [
        [ "alertes" ]
        [
          "unitesEnEchec"
          "servicesQuiRedemarrent"
        ]
        [ "ciblesDeCollecte" ]
        [
          "journauxExpedies"
          "timers"
        ]
      ];
    }
  ];

  places = lib.concatMap (s: lib.concatLists s.bands) squelette;

  sections = lib.filter (s: s.bands != [ ]) (
    map (
      s:
      s
      // {
        bands = lib.filter (b: b != [ ]) (
          map (b: map (n: panels.${n}) (lib.filter (n: panels ? ${n}) b)) s.bands
        );
      }
    ) squelette
  );

  dashboard = {
    uid = "${target.host}-systeme";
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

    # 1 = crosshair partagé ; 2 partagerait aussi l'infobulle, qui masquerait les courbes comparées.
    graphTooltip = 1;

    annotations.list = [
      {
        name = "Alertes";
        datasource = promDs;
        enable = false;
        hide = false;
        iconColor = "red";

        # Écrite deux fois (`expr` et `target`) : selon la migration du tableau, Grafana lit l'une ou l'autre.
        expr = q.alertesActives;
        target = {
          expr = q.alertesActives;
          refId = "Anno";
        };
        titleFormat = "{{alertname}}";
        textFormat = "{{severity}} · {{instance}}";
        step = "60s";
      }
    ];

    links = [
      {
        title = "Explorer";
        type = "link";
        icon = "doc";
        # Sans paramètres : la forme de l'URL présélectionnée a changé (`left=` puis `panes=`).
        url = "/explore";
        targetBlank = false;
        tooltip = "Recherche libre dans Loki et Prometheus, au-delà de ce que ce tableau montre.";
      }
      # Pas de lien vers Alertmanager : « Page not found » pour le rôle `Editor` (Grafana 13.0.6).
    ];

    # `hide` et `skipUrlSync` obligatoires : un bloc `templating` incomplet est rejeté en silence
    # et `${"$"}{unite:regex}` part littéralement dans la requête.
    templating.list = lib.optionals cfg.logs.enable [
      {
        name = "gravite";
        label = "Journaux : gravité";
        type = "custom";
        query = "error,warn,info,debug";
        multi = true;
        includeAll = false;
        hide = 0;
        skipUrlSync = false;
        current = {
          text = [
            "error"
            "warn"
          ];
          value = [
            "error"
            "warn"
          ];
        };
        options =
          map
            (v: {
              text = v;
              value = v;
              selected = v == "error" || v == "warn";
            })
            [
              "error"
              "warn"
              "info"
              "debug"
            ];
      }
      {
        # `allValue = ".+"` et non `.*`, que Loki refuse (sélecteur vide-compatible).
        name = "unite";
        label = "Journaux : unité";
        type = "query";
        datasource = lokiDs;

        # Forme objet : l'éditeur de variables de Loki attend une requête structurée. `type = 1` : valeurs d'une étiquette.
        query = {
          label = "unit";
          refId = "LokiVariableQueryEditor-VariableQuery";
          stream = "";
          type = 1;
        };
        definition = "label_values(unit)";

        multi = true;
        includeAll = true;
        allValue = ".+";
        refresh = 1;
        regex = "";
        sort = 1;
        hide = 0;
        skipUrlSync = false;
        options = [ ];
        current = {
          text = [ "All" ];
          value = [ "$__all" ];
        };
      }
      {
        name = "contient";
        label = "Journaux : contient";
        type = "textbox";
        query = "";
        hide = 0;
        skipUrlSync = false;
        options = [
          {
            selected = true;
            text = "";
            value = "";
          }
        ];
        current = {
          text = "";
          value = "";
        };
      }
    ];

    panels = placeSections sections;
  };

  dashboardsDir = pkgs-stable.linkFarm "grafana-dashboards" [
    {
      name = "systeme.json";
      path = pkgs-stable.writeText "systeme.json" (builtins.toJSON dashboard);
    }
  ];
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.subtractLists places (lib.attrNames panels) == [ ];
        message = "systemSettings.monitoring : panneau(x) placé(s) dans aucune bande (`squelette`, dashboard.nix), donc jamais affiché(s) : ${toString (lib.subtractLists places (lib.attrNames panels))}";
      }
    ];

    services.grafana.provision.dashboards.settings = {
      apiVersion = 1;
      providers = [
        {
          name = "dépôt";
          type = "file";
          allowUiUpdates = false;
          disableDeletion = true;
          options.path = dashboardsDir;
        }
      ];
    };
  };
}
