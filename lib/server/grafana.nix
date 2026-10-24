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

  mkDescription = description: lib.optionalAttrs (description != null) { inherit description; };

  # steps "green" [ 70 "orange" 90 "red" ] = vert sous 70, orange de 70 à 90, rouge au-delà.
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

  mkLogs =
    {
      id,
      title,
      expr,
      description ? null,
      h ? 12,
    }:
    {
      inherit id title h;
      type = "logs";
      datasource = lokiDs;
      options = {
        showTime = true;

        showLabels = false;
        showCommonLabels = false;

        wrapLogMessage = true;
        prettifyLogMessage = false;

        enableLogDetails = true;
        dedupStrategy = "none";

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
      description ? null,
      expr ? null,
      targets ? null,
      overrides ? [ ],
      graph ? true,
      justify ? "auto",
    }:
    {
      inherit id title;
      type = "stat";
      datasource = promDs;
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
        justifyMode = justify;
        # Tailles fixes : en automatique, une valeur avec courbe sort petite et une sans courbe
        # énorme, et une rangée de tuiles devient illisible.
        text = {
          valueSize = 30;
          titleSize = 13;
        };
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
      description ? null,
      unit ? "short",
      h ? 8,
      min ? 0,
      fill ? 10,
      stack ? false,
      decimals ? null,
      ds ? promDs,
      drawStyle ? "line",
      queryType ? null,
      # Regex des séries tracées SOUS L'AXE (`negative-Y`) ; à employer avec `min = null`.
      mirror ? null,
      overrides ? [ ],
      max ? null,
      legendCalcs ? [
        "lastNotNull"
        "max"
      ],
      # La légende du bas est plafonnée à 35 % de la hauteur (Grafana 13.0.6) : à droite si elle porte des valeurs.
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
          refId = toString (i + 1);
          datasource = ds;
          expr = t.expr;
          legendFormat = t.legend;
        }
        // lib.optionalAttrs (queryType != null) { inherit queryType; }
      ) targets;
    }
    // mkDescription description;

  mkStates =
    {
      id,
      title,
      targets,
      description ? null,
      h ? 10,
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

  # Depuis `ALERTS` de Prometheus et non d'Alertmanager (schéma `alertlist` instable) : alertes silencées perdues.
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
          instant = true;
          format = "table";
        }
      ];
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

  bandWidths =
    n:
    let
      w = 24 / n;
      reste = 24 - w * n;
    in
    lib.genList (i: if i < reste then w + 1 else w) n;

  bandOffsets = widths: lib.init (lib.foldl' (acc: w: acc ++ [ (lib.last acc + w) ]) [ 0 ] widths);

  bandHeight = lib.foldl' (m: p: if p.h > m then p.h else m) 0;

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

  # Row replié : ses panneaux vont dans son `panels` ; déplié, ce sont ses frères dans la liste.
  # Ids d'en-tête dès 100 pour ne pas heurter ceux des panneaux.
  placeSections =
    sections:
    (lib.foldl'
      (
        acc: section:
        let
          collapsed = section.collapsed or false;

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
