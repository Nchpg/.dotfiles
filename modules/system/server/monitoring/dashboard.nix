{
  config,
  lib,
  myLib,
  pkgs-stable,
  target,
  ...
}:

# TABLEAU DE BORD écrit à la main plutôt qu'importé.
#
# Le réflexe est d'importer « Node Exporter Full » (identifiant 1860), qui est
# excellent — et qui pèse deux cent mille lignes de JSON produites par une
# machine. Le poser dans ce dépôt-ci, c'est y verser un artefact que personne
# ne relira jamais en revue, pour cent quatre-vingts panneaux dont on en
# regarde six.
#
# Celui-ci s'ouvre sur six chiffres — dont un seul réclame une action, le
# compte d'alertes — puis descend vers ce dont on a besoin quand on cherche
# pourquoi, section par section : la machine, le stockage, ce qui est publié,
# les services, les journaux, et pour finir la surveillance elle-même. Chaque
# panneau porte une DESCRIPTION lisible dans l'interface (cf.
# `myLib.grafana.mkDescription`) : le raisonnement reste en Nix, la clé de
# lecture part là-bas.
#
# Il reste possible d'importer 1860 à la main depuis l'interface le jour où
# l'on creuse quelque chose de précis — il vivra alors dans l'état de Grafana,
# pas ici.
#
# CE FICHIER NE DÉFINIT QUE LE SQUELETTE : les panneaux sont déclarés par les
# composants (components/*.nix, dans `internal.panels`), à côté de l'exporteur
# et des règles qu'ils montrent. Les identifiants (`id`) y sont écrits à la
# main et NE SE RENUMÉROTENT PAS : un lien `viewPanel=` partagé ou mis en
# favori pointe sur eux.
let
  cfg = config.systemSettings.monitoring;
  inherit (cfg.internal) panels q;
  inherit (myLib.grafana) lokiDs promDs placeSections;

  # Sections, bandes, et noms des panneaux qui les composent. Un panneau absent
  # (composant coupé) est sauté, une bande vide disparaît, une section sans
  # bande aussi — la largeur des panneaux restants s'ajuste toute seule.
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
      # Section entière sous `apps.enable` : ses panneaux en dépendent tous.
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
        # Les deux surfaces d'authentification de la machine, qui se lisent
        # ensemble : ni Vaultwarden ni sshd n'exposent la moindre métrique.
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

      # DÉPLIÉE : une section repliée ne se déplie que si on pense à la
      # déplier, et on n'y pense pas quand tout a l'air normal. Or ces panneaux
      # disent justement si « tout a l'air normal » veut dire quelque chose.
      collapsed = false;
      bands = [
        # LA LISTE DES ALERTES SEULE DANS SA BANDE, sur toute la largeur. Une
        # ligne y porte le nom de l'alerte, sa gravité, la cible et les
        # étiquettes propres à la règle — la couper en deux colonnes
        # tronquerait la seule chose qu'on vient lire.
        [ "alertes" ]
        [
          "unitesEnEchec"
          "servicesQuiRedemarrent"
        ]
        # SEULE DANS SA BANDE, comme la liste des alertes : chaque bande d'état
        # porte son nom à gauche du graphique, et sur une demi-largeur ces noms
        # mangent le tiers du panneau.
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
    # Préfixé par la machine : chaque host a son tableau, et l'uid est ce que
    # portent les liens partagés (`/d/<uid>`).
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

    # CURSEUR PARTAGÉ ENTRE TOUS LES PANNEAUX (1 = crosshair ; 0 serait aucun
    # partage, 2 partagerait aussi l'infobulle).
    #
    # CE QUE ÇA CHANGE, et c'est le geste qu'on fait le plus souvent devant ce
    # tableau : survoler un pic sur une courbe pose une ligne verticale au même
    # instant sur TOUTES les autres. La question qu'on se pose devant un
    # décrochage est toujours « et les autres, à cette seconde-là ? ».
    #
    # `2` a été écarté : l'infobulle partagée ouvre une boîte sur chaque panneau
    # à la fois, ce qui masque les courbes qu'on essaie justement de comparer.
    graphTooltip = 1;

    # LES ALERTES DESSINÉES SUR TOUTES LES COURBES, en bandes verticales.
    #
    # CE QUE ÇA RÉPOND : devant un décrochage, la première question est « est-ce
    # que ça a alerté ? », et la seconde « qu'est-ce qui alertait AU MÊME
    # MOMENT ? ».
    #
    # Une annotation Prometheus rend une région pour chaque intervalle où la
    # série existe. `ALERTS{alertstate="firing"}` n'existe QUE pendant qu'une
    # alerte brûle : la bande couvre donc exactement sa durée, et son étiquette
    # porte le nom de l'alerte.
    #
    # `enable = false` PAR DÉFAUT, et c'est un vrai choix : les bandes sont utiles
    # quand on enquête et encombrantes quand on regarde une courbe. Grafana pose
    # une case à cocher en haut du tableau, à côté des filtres de journal — on
    # les allume le jour où on en a besoin.
    annotations.list = [
      {
        name = "Alertes";
        datasource = promDs;
        enable = false;
        hide = false;
        iconColor = "red";

        # LA REQUÊTE ÉCRITE DEUX FOIS, ET C'EST DÉLIBÉRÉ. Grafana a déplacé la
        # requête d'annotation de la racine de l'objet (`expr`, la forme
        # historique) vers un sous-objet `target`, et les deux formes se
        # rencontrent encore selon la version et selon que le tableau a été
        # migré ou non. Se tromper de forme ne produirait aucune erreur : les
        # bandes ne s'afficheraient simplement jamais.
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

    # RACCOURCIS vers ce qui n'est pas dans le tableau.
    links = [
      {
        title = "Explorer";
        type = "link";
        icon = "doc";
        # SANS PARAMÈTRES, délibérément : l'URL qui présélectionne une source et
        # une requête a changé de forme entre les versions de Grafana (`left=`
        # puis `panes=`), et un lien qui ouvre une page d'erreur est pire que pas
        # de lien. Explore s'ouvre sur la dernière source employée.
        url = "/explore";
        targetBlank = false;
        tooltip = "Recherche libre dans Loki et Prometheus, au-delà de ce que ce tableau montre.";
      }
      # PAS DE LIEN VERS ALERTMANAGER. `/alerting/groups?alertmanager=Alertmanager`
      # CHARGE, mais Grafana surimpose « Page not found » : les pages touchant à
      # un Alertmanager externe demandent des droits que le rôle `Editor` n'a
      # pas, donc le chrome ne trouve aucune page à nommer (relevé dans le
      # bundle de Grafana 13.0.6).
      #
      # Monter le rôle n'est pas une option, cf. `auto_assign_org_role` dans
      # grafana.nix. Ce qu'on ne perd pas : « qu'est-ce qui brûle en ce moment »
      # est répondu par la table « Alertes en cours » ; les silences et le
      # routage se consultent par un tunnel SSH vers 127.0.0.1:9093.
    ];

    # FILTRES DE JOURNAL, en haut du tableau.
    #
    # Ils rendent le tri INTERACTIF : on trie en regardant, on ne fige que ce qui
    # mérite de l'être. Ils ne dispensent pas des reclassements écrits dans
    # Vector : ce qui est FAUX à la source — une erreur dbus qui n'en est pas
    # une — se corrige à la source. Ce qui est simplement HORS SUJET du moment
    # se filtre ici.
    #
    # PORTÉE : Grafana n'a pas de filtre par section, une variable vaut pour
    # tout le tableau. Elles ne sont lues que par les panneaux de la section
    # « Journaux », d'où le préfixe « Journaux : » sur chaque libellé — sans
    # lui, on croirait qu'elles filtrent aussi les courbes.
    #
    # `hide` ET `skipUrlSync` SONT OBLIGATOIRES sur chacune, aussi inutiles
    # qu'ils paraissent. Grafana les écrit systématiquement quand il enregistre
    # un tableau, et son schéma les attend : un bloc `templating` incomplet est
    # REJETÉ EN SILENCE — aucune erreur de provisioning, simplement aucune
    # variable. Et sans variable, `${"$"}{unite:regex}` part littéralement dans
    # la requête, qui ne correspond alors à rien.
    templating.list = lib.optionals cfg.logs.enable [
      {
        # `multi` sans `includeAll` : les quatre gravités sont connues d'avance
        # et tiennent à l'écran. Défaut sur error+warn.
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
        # Liste construite à l'exécution depuis Loki : une unité ajoutée au host
        # apparaît sans qu'on touche à ce fichier. `refresh = 1` la recalcule au
        # chargement du tableau.
        #
        # `allValue = ".+"` ET SURTOUT PAS `.*`, qui est le réflexe et que Loki
        # REFUSE :
        #
        #   queries require at least one regexp or equality matcher that does
        #   not have an empty-compatible value
        #
        # Le panneau de VOLUME n'a que ce sélecteur-ci, et tombait donc en erreur
        # d'analyse avec `.*`. C'est aussi plus court que le `$__all` par défaut,
        # qui produirait la liste complète des unités dans chaque requête.
        name = "unite";
        label = "Journaux : unité";
        type = "query";
        datasource = lokiDs;

        # FORME OBJET ET NON LA CHAÎNE `label_values(unit)`. Cette dernière est
        # la syntaxe historique, comprise par le type de source Prometheus ;
        # l'éditeur de variables de Loki attend une requête STRUCTURÉE, et une
        # chaîne le laisse sans valeurs.
        #
        # `type = 1` est l'énumération de Loki pour « valeurs d'une étiquette »
        # (0 étant « noms des étiquettes »). `definition` n'est que le libellé
        # affiché dans l'éditeur.
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
        # Recherche en plein texte. Vide par défaut, ce qui donne `|= ""` —
        # un filtre qui laisse tout passer, vérifié.
        #
        # UNE INCLUSION ET NON UNE EXCLUSION, à dessein : un `!= "$var"` vide
        # donnerait `!= ""`, qui exclut TOUTE ligne contenant la chaîne vide,
        # c'est-à-dire toutes.
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
}
