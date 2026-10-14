# Constructeurs de panneaux Grafana et mise en page du tableau de bord, pour
# modules/system/server/monitoring (exposés sous `myLib.grafana`).
#
# Fonctions PURES : elles ne lisent aucune option. Ce qui dépend de la machine
# (requêtes, seuils, conditions) reste dans les modules qui les appellent.
lib:

let
  promDs = {
    type = "prometheus";
    uid = "prometheus";
  };

  lokiDs = {
    type = "loki";
    uid = "loki";
  };

  # CE QUE LA DESCRIPTION RÈGLE, et qui n'était réglé nulle part : tout ce que
  # le dépôt sait d'un panneau est écrit dans ses commentaires Nix, c'est-à-dire
  # à l'endroit exact où personne ne se trouve au moment où la question se pose.
  # Devant une courbe à 3 h du matin, on ne va pas ouvrir le dépôt pour savoir
  # pourquoi les écritures sont tracées vers le bas.
  #
  # Grafana affiche ce texte dans une infobulle sous le « ⓘ » du titre. Une
  # phrase, jamais le commentaire entier : ce qui explique une DÉCISION reste en
  # Nix, à destination de qui modifie ; ce qui explique la LECTURE part dans
  # l'interface, à destination de qui regarde. Les deux publics ne sont pas les
  # mêmes et ne lisent pas au même moment.
  mkDescription = description: lib.optionalAttrs (description != null) { inherit description; };

  # Paliers de couleur d'un seuil Grafana, écrits à plat :
  #
  #   steps "green" [ 70 "orange" 90 "red" ]
  #
  # donne le vert sous 70, l'orange de 70 à 90, le rouge au-delà. Le premier
  # palier a toujours `value = null` (« tout ce qui est en dessous »), c'est la
  # forme que Grafana attend.
  steps =
    base: paliers:
    let
      go =
        l:
        if l == [ ] then
          [ ]
        else
          [
            {
              color = lib.elemAt l 1;
              value = lib.head l;
            }
          ]
          ++ go (lib.drop 2 l);
    in
    [
      {
        color = base;
        value = null;
      }
    ]
    ++ go paliers;

  byName = options: {
    id = "byName";
    inherit options;
  };

  byRegexp = options: {
    id = "byRegexp";
    inherit options;
  };

  # LIGNE DE RÉFÉRENCE (un seuil d'alerte, un plafond) tracée avec la mesure :
  # grise, en pointillés, sans remplissage. C'est un repère, pas une mesure de
  # plus — sans couleur fixe, la palette lui donnerait une teinte vive qu'on
  # prendrait pour une série réelle.
  #
  # NOMMÉE DANS LA LÉGENDE, TUE DANS L'INFOBULLE. Une constante n'a rien à dire
  # au survol, mais elle doit dire son nom quelque part : un trait pointillé
  # anonyme en travers d'un graphique est une question de plus posée au
  # lecteur.
  #
  # `matcher` désigne les séries concernées par leur légende (`byName` ou
  # `byRegexp`).
  thresholdLine = matcher: {
    inherit matcher;
    properties = [
      {
        id = "custom.lineStyle";
        value = {
          fill = "dash";
          dash = [
            10
            10
          ];
        };
      }
      {
        id = "custom.fillOpacity";
        value = 0;
      }
      {
        id = "color";
        value = {
          mode = "fixed";
          fixedColor = "text";
        };
      }
      {
        id = "custom.hideFrom";
        value = {
          legend = false;
          tooltip = true;
          viz = false;
        };
      }
    ];
  };

  # Panneau de JOURNAL, à ne pas confondre avec un panneau de courbes qui
  # tracerait un volume de journal. Son schéma d'options n'a rien de commun avec
  # celui de `mkTs` — pas de `fieldConfig`, pas d'axes, pas de légende — d'où un
  # constructeur à lui plutôt qu'un paramètre de plus sur l'autre.
  #
  # À LAISSER SEUL DANS SA BANDE : une ligne de journal fait couramment cent
  # cinquante caractères, et la couper en deux colonnes la rend illisible sans
  # rien gagner. Lui donner un voisin n'échouerait pas, ça produirait un panneau
  # inutilisable.
  mkLogs =
    {
      id,
      title,
      expr,
      # Une phrase affichée sous le « ⓘ » du panneau, cf. `mkDescription`.
      description ? null,
      h ? 12,
    }:
    {
      inherit id title h;
      type = "logs";
      datasource = lokiDs;
      options = {
        # L'horodatage est la raison d'être du panneau : c'est lui qui permet de
        # recoller une ligne à un décrochage vu sur une courbe au-dessus.
        showTime = true;

        # Les étiquettes RESTENT masquées dans la liste, et se déplient ligne par
        # ligne (`enableLogDetails`). Affichées en permanence, elles occupent la
        # moitié de la largeur avec la même valeur répétée cent fois.
        showLabels = false;
        showCommonLabels = false;

        # Le message entier plutôt qu'une ligne tronquée : une trace d'erreur
        # coupée à la largeur du panneau ne sert à rien.
        wrapLogMessage = true;
        prettifyLogMessage = false;

        enableLogDetails = true;
        dedupStrategy = "none";

        # Le plus RÉCENT en haut. L'ordre inverse obligerait à faire défiler
        # jusqu'en bas pour voir ce qui vient de se passer, ce qui est
        # précisément ce qu'on ouvre le panneau pour lire.
        sortOrder = "Descending";
      };
      targets = [
        {
          refId = "1";
          datasource = lokiDs;
          inherit expr;
          queryType = "range";
        }
      ];
    }
    // mkDescription description;

  mkStat =
    {
      id,
      title,
      unit,
      steps,
      # Une phrase affichée sous le « ⓘ » du panneau, cf. `mkDescription`. Elle
      # vaut plus encore sur un chiffre-clé que sur une courbe : la boîte ne
      # porte qu'un nombre et un titre de deux mots, donc tout le reste — sur
      # quoi il est calculé, à partir de quand il faut s'en inquiéter — n'est
      # écrit nulle part dans l'interface.
      description ? null,
      # UNE mesure — le cas de tous les chiffres-clés sauf un.
      expr ? null,
      # PLUSIEURS mesures dans la même boîte, chacune avec son libellé. Grafana
      # les dispose côte à côte dans le panneau, ce qui donne une fiche
      # signalétique plutôt qu'un chiffre isolé.
      targets ? null,
      # Surcharges par série, nécessaires dès que les mesures d'une même boîte
      # ne partagent pas la même unité : un compte de cœurs à côté d'octets.
      overrides ? [ ],
      # Courbe de fond derrière le chiffre.
      #
      # UTILE quand la valeur bouge — elle donne la tendance sans coûter de
      # place. INUTILE sur une CONSTANTE : tracer une droite plate derrière
      # « 4 cœurs » n'apprend rien, et devient franchement trompeur quand
      # plusieurs constantes d'ordres de grandeur différents partagent le
      # panneau.
      graph ? true,
    }:
    {
      inherit id title;
      type = "stat";
      datasource = promDs;
      # Hauteur seulement : la POSITION est calculée par `placeSections`. Un
      # chiffre-clé tient en quatre lignes de grille, moitié moins qu'une
      # courbe.
      h = 4;
      fieldConfig = {
        defaults = {
          inherit unit;
          color.mode = "thresholds";
          thresholds = {
            mode = "absolute";
            inherit steps;
          };
        };
        inherit overrides;
      };
      options = {
        colorMode = "value";
        graphMode = if graph then "area" else "none";
        justifyMode = "auto";
        # `value_and_name` dès qu'il y a plusieurs mesures : sans le nom, trois
        # nombres côte à côte ne disent pas lequel est lequel. Sur une mesure
        # unique le titre du panneau suffit, d'où `auto`.
        textMode = if targets == null then "auto" else "value_and_name";
        reduceOptions = {
          calcs = [ "lastNotNull" ];
          fields = "";
          values = false;
        };
      };
      targets =
        if targets == null then
          [
            {
              refId = "A";
              datasource = promDs;
              inherit expr;
            }
          ]
        else
          lib.imap0 (i: t: {
            refId = toString (i + 1);
            datasource = promDs;
            expr = t.expr;
            legendFormat = t.legend;
          }) targets;
    }
    // mkDescription description;

  mkTs =
    {
      id,
      title,
      targets,
      # Une phrase affichée sous le « ⓘ » du panneau, cf. `mkDescription`.
      description ? null,
      unit ? "short",
      # Hauteur seulement, comme `mkStat` : la position vient de la disposition.
      h ? 8,
      min ? 0,
      fill ? 10,
      stack ? false,
      # Chiffres après la virgule. `null` — le défaut — laisse Grafana décider,
      # ce qui convient partout sauf aux TAUX : `rate()` produit une moyenne,
      # donc une valeur fractionnaire même quand ce qu'on compte est entier par
      # nature. « 24,7 requêtes par minute » est exact et illisible ; poser 0 ici
      # arrondit l'AFFICHAGE sans toucher à la donnée, que l'infobulle montre
      # toujours en entier.
      decimals ? null,
      # Source de données du panneau : Prometheus, sauf pour les décomptes tirés
      # du journal, qui interrogent Loki.
      ds ? promDs,
      # `bars` pour un décompte d'événements : une courbe lissée entre deux
      # points suggère une continuité qui n'existe pas quand on compte des
      # lignes de journal par intervalle.
      drawStyle ? "line",
      # Loki distingue requête instantanée et requête sur plage, et veut le
      # savoir. Prometheus n'a pas ce champ, d'où l'omission pure quand il est
      # nul plutôt qu'une valeur vide qui embrouillerait le JSON.
      queryType ? null,
      # Expression régulière désignant les séries à TRACER SOUS L'AXE, pour un
      # flux bidirectionnel — lecture au-dessus, écriture en dessous.
      #
      # POURQUOI PAS UN SIGNE MOINS DANS LA REQUÊTE, qui produit le même
      # dessin : parce qu'il nie la DONNÉE et pas seulement son tracé. La
      # légende et l'infobulle afficheraient « -3,2 Mo/s », ce qui n'existe pas
      # — on n'écrit pas une quantité négative d'octets.
      #
      # `negative-Y` est le réglage que Grafana prévoit pour ça : il retourne le
      # TRACÉ, la valeur reste positive partout où elle est lue.
      #
      # À employer avec `min = null`, sans quoi l'axe reste borné à zéro et la
      # moitié inférieure du graphique n'existe pas.
      mirror ? null,
      # Surcharges Grafana supplémentaires, par série : un couple
      # { matcher, properties } qui désigne des séries par nom et leur applique
      # des réglages que le panneau porte globalement (cf. `thresholdLine`).
      overrides ? [ ],
      # Borne HAUTE de l'axe. Nulle par défaut — Grafana s'ajuste à la donnée,
      # ce qui est le bon comportement pour une grandeur sans plafond.
      #
      # À POSER SUR LES POURCENTAGES, où l'ajustement automatique est franchement
      # trompeur : un disque occupé entre 61,2 et 61,4 % remplit tout le
      # graphique d'une courbe qui monte et descend spectaculairement. Borné à
      # 100, le même panneau montre ce qu'il faut voir — une ligne plate très
      # haut, ou très bas.
      max ? null,
      # Calculs affichés à côté de chaque série dans la légende. La liste vide
      # rend la légende en LISTE, c'est-à-dire des noms seuls.
      #
      # Le défaut affiche la dernière valeur et le maximum : sans eux, lire la
      # valeur courante d'une série suppose de survoler la courbe à la souris —
      # donc c'est impossible sur un téléphone, qui est précisément l'appareil
      # qu'on a en main quand une alerte tombe. Le maximum répond à la question
      # qui suit toujours : « ça monte à combien, au pire ? ».
      legendCalcs ? [
        "lastNotNull"
        "max"
      ],
      # Où poser la légende. DÉDUIT et non réglé : une légende qui porte des
      # valeurs va à DROITE, une légende qui ne porte que des noms va en bas.
      #
      # POURQUOI CE N'EST PAS UN GOÛT. Grafana plafonne la hauteur de la légende
      # du BAS à 35 % de celle du panneau, et sa largeur à 60 % quand elle est à
      # droite. Relevé dans le binaire de Grafana 13.0.6 plutôt que supposé :
      #
      #   renderLegend(…) … maxHeight:"35%", maxWidth:"60%"
      #
      # Ce que ça donne en lignes, une ligne de table faisant 22 pixels avec un
      # en-tête de colonnes de même hauteur :
      #
      #   - panneau `h = 8` → 93 pixels de légende → l'en-tête et TROIS séries ;
      #   - panneau `h = 6` → 66 pixels → l'en-tête et DEUX séries.
      #
      # Pile, sans marge : un nom un peu long qui passe à la ligne suffit à
      # rendre la légende défilante. À DROITE, en revanche, elle dispose de
      # toute la hauteur — douze séries à `h = 8`, huit à `h = 6`. Elle prend de
      # la largeur, ce qui est le bon échange : une courbe perd peu à être moins
      # large, elle perd tout à être moins haute.
      #
      # Le compte de séries n'est pas connu à la construction — il dépend de ce
      # que rend la requête, et il grandit tout seul —, d'où un défaut déduit
      # plutôt qu'un choix panneau par panneau.
      legendPlacement ? (if legendCalcs == [ ] then "bottom" else "right"),
    }:
    {
      inherit id title h;
      type = "timeseries";
      datasource = ds;
      fieldConfig = {
        defaults = {
          inherit
            unit
            min
            max
            decimals
            ;
          color.mode = "palette-classic";
          custom = {
            inherit drawStyle;
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
        overrides =
          lib.optional (mirror != null) {
            matcher = byRegexp mirror;
            properties = [
              {
                id = "custom.transform";
                value = "negative-Y";
              }
            ];
          }
          ++ overrides;
      };
      options = {
        legend = {
          # `table` dès qu'il y a des chiffres à porter : le mode `list` les
          # accepte dans le JSON et ne les affiche jamais, ce qui donne un
          # panneau qui a l'air correct et ne montre rien de plus.
          displayMode = if legendCalcs == [ ] then "list" else "table";
          placement = legendPlacement;
          showLegend = true;
          calcs = legendCalcs;
        };
        tooltip = {
          mode = "multi";
          sort = "desc";
        };
      };
      targets = lib.imap0 (
        i: t:
        {
          # `refId` doit seulement être UNIQUE dans le panneau ; les lettres qu'on
          # voit dans l'interface sont une convention, pas une contrainte de
          # format. Un compteur n'a pas de borne, là où une liste de lettres
          # écrite à la main ferait échouer l'évaluation à la première cible de
          # trop.
          refId = toString (i + 1);
          datasource = ds;
          expr = t.expr;
          legendFormat = t.legend;
        }
        // lib.optionalAttrs (queryType != null) { inherit queryType; }
      ) targets;
    }
    // mkDescription description;

  # BANDES D'ÉTAT, pour ce qui ne vaut QUE 0 ou 1. Une courbe est le mauvais
  # dessin pour ça : vingt séries qui valent toutes 1 se superposent en UNE
  # SEULE ligne, sous laquelle dix-neuf autres sont invisibles. On ne voit donc
  # pas qu'une série est tombée, sauf à survoler la seule ligne visible.
  #
  # Le state-timeline donne une bande par série, empilées, vertes ou rouges. La
  # panne se voit sans lire, ce qui est exactement ce qu'on demande à un panneau
  # qu'on croise en faisant défiler.
  #
  # `mergeValues` fusionne les intervalles consécutifs de même valeur : sans lui,
  # chaque point de collecte devient un rectangle et la bande ressemble à un
  # code-barres.
  mkStates =
    {
      id,
      title,
      targets,
      description ? null,
      h ? 10,
      # Ce que valent 0 et 1 en toutes lettres. Les mêmes deux mots partout
      # seraient plus courts et moins justes : « hors service » convient à une
      # cible de collecte, pas à une unité systemd.
      labels ? {
        "0" = "hors service";
        "1" = "en service";
      },
    }:
    {
      inherit id title h;
      type = "state-timeline";
      datasource = promDs;
      fieldConfig = {
        defaults = {
          color.mode = "thresholds";
          thresholds = {
            mode = "absolute";
            steps = steps "red" [
              1
              "green"
            ];
          };
          custom = {
            lineWidth = 0;
            fillOpacity = 80;
          };
          mappings = [
            {
              type = "value";
              options = lib.mapAttrs (_: text: { inherit text; }) labels;
            }
          ];
        };
        overrides = [ ];
      };
      options = {
        showValue = "never";
        mergeValues = true;
        alignValue = "left";
        rowHeight = 0.9;
        # Le nom de chaque série est déjà écrit à gauche de sa bande : une
        # légende en dessous le répéterait vingt fois pour rien.
        legend = {
          displayMode = "list";
          placement = "bottom";
          showLegend = false;
        };
        tooltip = {
          mode = "single";
          sort = "none";
        };
      };
      targets = lib.imap0 (i: t: {
        refId = toString (i + 1);
        datasource = promDs;
        expr = t.expr;
        legendFormat = t.legend;
      }) targets;
    }
    // mkDescription description;

  # LA LISTE DES ALERTES QUI BRÛLENT, depuis la série `ALERTS` que Prometheus
  # publie pour ses propres alertes actives.
  #
  # DEPUIS PROMETHEUS ET NON DEPUIS ALERTMANAGER : `ALERTS` est une série
  # ordinaire que n'importe quel panneau sait lire, ce qui évite de dépendre du
  # schéma du panneau `alertlist`, qui bouge d'une version de Grafana à
  # l'autre. Ce qu'on y perd : les alertes SILENCÉES, qui n'existent que côté
  # Alertmanager.
  #
  # `expr` est la sélection des alertes actives ; c'est à l'appelant d'en
  # exclure le watchdog, qui brûle en permanence par construction.
  mkAlertes =
    { id, expr }:
    {
      inherit id;
      title = "Alertes en cours";
      description = "Les alertes que Prometheus considère comme actives en ce moment, watchdog exclu. Un panneau vide est l'état normal.";
      type = "table";
      datasource = promDs;
      h = 8;
      fieldConfig = {
        defaults = {
          # LE MESSAGE QUI COMPTE : sans lui, Grafana écrit « No data » sur un
          # panneau dont l'état normal est d'être vide. Or « No data » veut dire
          # aussi bien « aucune alerte » que « la source ne répond plus ». Le
          # texte affirme donc que la mesure a bien eu lieu.
          noValue = "Aucune alerte active.";
          custom.align = "left";
        };
        overrides = [
          {
            matcher = byName "Gravité";
            properties = [
              {
                id = "custom.cellOptions";
                value.type = "color-text";
              }
              {
                id = "mappings";
                value = [
                  {
                    type = "value";
                    options = {
                      critical = {
                        text = "critique";
                        color = "red";
                        index = 0;
                      };
                      warning = {
                        text = "avertissement";
                        color = "orange";
                        index = 1;
                      };
                    };
                  }
                ];
              }
            ];
          }
        ];
      };
      options = {
        showHeader = true;
        # Par gravité CROISSANTE, ce qui met « critical » avant « warning » —
        # l'ordre alphabétique tombe juste, pour une fois.
        sortBy = [
          {
            displayName = "Gravité";
            desc = false;
          }
        ];
      };
      targets = [
        {
          refId = "1";
          datasource = promDs;
          inherit expr;
          # `instant` : on veut l'état MAINTENANT, pas son historique. Sans lui,
          # la table reçoit une série temporelle entière et n'affiche qu'une
          # bouillie de points.
          instant = true;
          format = "table";
        }
      ];
      # Les colonnes que Prometheus ajoute et qui ne disent rien ici : l'instant
      # de la mesure, la valeur (toujours 1), le nom de la métrique (toujours
      # `ALERTS`), l'état (toujours `firing` puisqu'il est filtré) et la tâche de
      # collecte. Ce qui reste — le nom de l'alerte, sa gravité, la cible, et les
      # étiquettes propres à chaque règle comme `mountpoint` ou `device` — est
      # exactement ce qu'on lit dans le message Discord.
      transformations = [
        {
          id = "organize";
          options = {
            excludeByName = {
              Time = true;
              Value = true;
              "__name__" = true;
              alertstate = true;
              job = true;
            };
            renameByName = {
              alertname = "Alerte";
              severity = "Gravité";
              instance = "Cible";
            };
          };
        }
      ];
    };

  # ------------------------------------------------------------- disposition
  #
  # LE TABLEAU SE DÉCRIT, SES COORDONNÉES SE CALCULENT. Écrire `x` et `y` à la
  # main coûte deux choses dont aucune n'est cosmétique :
  #
  #   - insérer un panneau au milieu oblige à renuméroter tous les suivants.
  #     Personne ne le fait, donc tout nouveau panneau finit À LA FIN quel que
  #     soit son sujet ;
  #   - un `y` dupliqué ne fait RIEN échouer. Grafana superpose simplement les
  #     deux panneaux, ce qui se découvre à l'œil, plus tard.
  #
  # Le tableau est donc une liste de SECTIONS, chacune une liste de BANDES
  # horizontales, chaque bande une liste de panneaux qui se partagent les
  # vingt-quatre colonnes. Réordonner devient déplacer une ligne, et les
  # coordonnées ne peuvent plus se contredire puisque personne ne les écrit.

  # Largeurs d'une bande. Les colonnes que la division entière laisse
  # (24 / 5 = 4, il en reste 4) sont RÉPARTIES SUR LES PREMIERS, une chacun : une
  # bande de cinq donne 5-5-5-5-4 plutôt que 4-4-4-4-8, où le dernier panneau
  # ferait le double des autres sans raison.
  bandWidths =
    n:
    let
      w = 24 / n;
      reste = 24 - w * n;
    in
    lib.genList (i: if i < reste then w + 1 else w) n;

  # Décalages horizontaux cumulés, déduits des largeurs.
  bandOffsets = widths: lib.init (lib.foldl' (acc: w: acc ++ [ (lib.last acc + w) ]) [ 0 ] widths);

  # Hauteur d'une bande : celle de son panneau le plus haut, sinon la bande
  # suivante viendrait le chevaucher.
  bandHeight = lib.foldl' (m: p: if p.h > m then p.h else m) 0;

  # Pose une bande à l'ordonnée donnée. Le `h` que portent les constructeurs
  # migre dans `gridPos` et disparaît du panneau : Grafana ne connaît pas
  # d'attribut `h` à la racine, l'y laisser polluerait le JSON.
  placeBand =
    y: band:
    let
      widths = bandWidths (lib.length band);
      xs = bandOffsets widths;
    in
    lib.imap0 (
      i: p:
      removeAttrs p [ "h" ]
      // {
        gridPos = {
          inherit y;
          inherit (p) h;
          w = lib.elemAt widths i;
          x = lib.elemAt xs i;
        };
      }
    ) band;

  # Empile les sections et rend la liste de panneaux que Grafana attend.
  #
  # UN EN-TÊTE DE SECTION EST UN PANNEAU comme un autre, de type `row` et haut
  # d'une seule ligne de grille. Deux formes selon qu'il est replié ou non, et
  # ce n'est pas un détail de rendu : DÉPLIÉ, ses panneaux sont ses FRÈRES dans
  # la liste principale ; REPLIÉ, ils vivent dans son propre attribut `panels`.
  # Se tromper de forme donne une section vide, sans erreur.
  #
  # Les identifiants des en-têtes partent de 100 pour ne pas entrer en collision
  # avec ceux des panneaux, qui sont écrits à la main.
  placeSections =
    sections:
    (lib.foldl'
      (
        acc: section:
        let
          collapsed = section.collapsed or false;

          # Les bandes de la section, empilées sous son en-tête.
          stacked =
            lib.foldl'
              (a: band: {
                y = a.y + bandHeight band;
                panels = a.panels ++ placeBand a.y band;
              })
              {
                y = acc.y + 1;
                panels = [ ];
              }
              section.bands;

          header = {
            id = 100 + acc.n;
            type = "row";
            inherit (section) title;
            inherit collapsed;
            panels = if collapsed then stacked.panels else [ ];
            gridPos = {
              h = 1;
              w = 24;
              x = 0;
              y = acc.y;
            };
          };
        in
        {
          n = acc.n + 1;
          # Repliée, la section n'occupe que la ligne de son en-tête.
          y = if collapsed then acc.y + 1 else stacked.y;
          panels = acc.panels ++ [ header ] ++ lib.optionals (!collapsed) stacked.panels;
        }
      )
      {
        n = 0;
        y = 0;
        panels = [ ];
      }
      sections
    ).panels;
in
{
  inherit
    promDs
    lokiDs
    mkDescription
    steps
    byName
    byRegexp
    thresholdLine
    mkLogs
    mkStat
    mkTs
    mkStates
    mkAlertes
    placeSections
    ;
}
