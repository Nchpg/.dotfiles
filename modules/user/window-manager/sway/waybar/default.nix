{
  config,
  lib,
  myLib,
  ...
}:

# Barre de la session sway (SEULE barre du dépôt : sway n'émet plus aucun
# bloc `bar {}` natif). Blocs cliquables via les launchers
# ~/.config/sway/launchers/*, fournis par les modules voisins ../pickers/* et
# par tui/lg-control et tui/calendar. Découpé en scripts.nix (scripts des
# modules custom), nightlight.nix (wlsunset), thunar-float/ (clic disque) et
# style.css.
let
  sway = config.userSettings.windowManager.sway;
  cfg = sway.waybar;
  inherit (cfg) pkgs;

  c = config.lib.stylix.colors.withHashtag;

  home = config.home.homeDirectory;
  launcher = name: "${home}/.config/sway/launchers/${name}";

  # Câblé UNIQUEMENT si le module est activé pour le user, sinon pas
  # d'attribut on-click du tout (bloc affiché, clic inactif) : rend la barre
  # composable pour un user minimal (guest).
  # Chemin inexistant = ERREUR d'éval, pas un `false` silencieux, cf.
  # lib/modules/option-enabled.nix.
  clickIf =
    modulePath: name:
    lib.optionalAttrs (myLib.optionEnabled config.userSettings modulePath) {
      on-click = launcher name;
    };

  inherit (myLib.desktop) mkIcon;

  # Icône suivie de l'espacement standard de la barre (3 espaces) avant le texte.
  labeled = hex: text: "${mkIcon hex}   ${text}";

  # Référencés explicitement (clics) pour ne pas dépendre du PATH.
  playerctl = "${pkgs.playerctl}/bin/playerctl";
  swaync = "${pkgs.swaynotificationcenter}/bin/swaync-client";

  # programs.btop (pas pkgs.btop, amont driver i915-only) : support GPU xe
  # (PR #1457) si activé côté user.
  btop = "${config.programs.btop.package}/bin/btop";

  # Empaquetés par ./scripts.nix, qui possède aussi ce chemin.
  inherit (cfg) scriptDir;

  # Commandes volume : les mêmes que les touches clavier (module sway).
  inherit (sway) volume;
  volScroll = {
    on-scroll-up = volume.up;
    on-scroll-down = volume.down;
  };

  # Menus clic droit : XML + menu-actions tirés d'une même liste (cf.
  # lib/desktop/waybar-menu.nix). Ids GTK = vol<N> / pct<N> (pas de chiffre en
  # tête), une seule source pour les préréglages : volumePresets /
  # backlightPresets.
  menus = {
    volume = myLib.desktop.mkWaybarMenu (
      [
        {
          id = "mute";
          label = "Mute / Unmute";
          action = volume.mute;
        }
        "sep"
        {
          id = "mixer";
          label = "Ouvrir le mixer";
          # Entrée affichée même sans le mixeur, mais muette.
          action = if sway.pickers.volume.enable then launcher "volume-mixer" else null;
        }
        "sep"
      ]
      ++ map (p: {
        id = "vol${toString p}";
        label = "${toString p} %";
        action = "${volume.set} ${toString p}%";
      }) cfg.volumePresets
      ++ [
        "sep"
        {
          id = "volup";
          label = "Volume +5 %";
          action = volume.up;
        }
        {
          id = "voldown";
          label = "Volume -5 %";
          action = volume.down;
        }
      ]
    );

    # Le choix PERSISTE dans le cache météo (weather-city.sh), survit aux
    # reboots, et sert aussi de lieu au night light.
    weather = myLib.desktop.mkWaybarMenu (
      map (city: {
        id = city;
        label = city;
        action = "${scriptDir}/weather-city.sh ${lib.escapeShellArg city}";
      }) cfg.weatherCities
    );

    # Luminosité : la même commande que les touches clavier (module sway),
    # qui rafraîchit elle-même cette case.
    backlight = myLib.desktop.mkWaybarMenu (
      [
        {
          id = "mode";
          label = "Changer de mode (night light)";
          action = nightlightToggle;
        }
        "sep"
      ]
      ++ map (p: {
        id = "pct${toString p}";
        label = "${toString p} %";
        action = "${brightness} set ${toString p}";
      }) cfg.backlightPresets
      ++ [
        "sep"
        {
          id = "inc";
          label = "+5 %";
          action = "${brightness} up";
        }
        {
          id = "dec";
          label = "−5 %";
          action = "${brightness} down";
        }
      ]
    );

    notifications = myLib.desktop.mkWaybarMenu [
      {
        id = "dnd";
        label = "Ne pas déranger (on/off)";
        action = "${swaync} -d -sw";
      }
      "sep"
      {
        id = "panel";
        label = "Afficher les notifications";
        action = "${swaync} -t -sw";
      }
    ];
  };
  menuDir = "${home}/.config/waybar/menus";
  # Attributs d'un module pour son menu clic droit.
  withMenu = name: {
    menu = "on-click-right";
    menu-file = "${menuDir}/${name}.xml";
    menu-actions = menus.${name}.actions;
  };

  weatherWake = cfg.refresh.weather;

  brightness = lib.getExe sway.brightness;
  # Night light : cf. ./nightlight.nix et scripts/nightlight.sh.
  nightlightToggle = "${scriptDir}/nightlight.sh toggle";

  # CSS dans ./style.css, @nom@ remplacés ici : couleurs base16/base24 de
  # stylix et polices.
  styleVars = {
    font = config.stylix.fonts.sansSerif.name;
    # Nerd Font (glyphes des icônes) + emoji en dernier recours.
    nerdFont = config.stylix.fonts.monospace.name;
    emojiFont = config.stylix.fonts.emoji.name;
    fontSize = toString config.stylix.fonts.sizes.desktop;
  }
  // lib.genAttrs [
    "base00"
    "base01"
    "base02"
    "base03"
    "base04"
    "base05"
    "base09"
    "base0A"
    "base0B"
    "base0C"
    "base0D"
    "base0E"
    "bright-red"
    "bright-yellow"
  ] (n: c.${n});
  style = lib.replaceStrings (map (n: "@${n}@") (
    lib.attrNames styleVars
  )) (lib.attrValues styleVars) (builtins.readFile ./style.css);

  # Base du module swaync (cloche + nombre). Le tooltip natif de swaync
  # (« N Notification(s) ») est laissé actif.
  swayncBase = {
    exec = "${swaync} -swb";
    return-type = "json";
  };
  bell = mkIcon "f009a"; # md-bell
  bellOff = mkIcon "f009b"; # md-bell-off
in
{
  options.userSettings.windowManager.sway.waybar = {
    # Suit sway par défaut. ATTENTION : pas de fallback, waybar.enable = false
    # donne une session sway SANS AUCUNE barre (choix légitime pour un user minimal).
    enable = lib.mkEnableOption "waybar (seule barre de la session sway)" // {
      default = config.userSettings.windowManager.sway.enable;
    };

    pkgs = myLib.mkPkgsOption { inherit lib config; };

    weatherCities = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "Angers"
        "Paris"
      ];
      description = ''
        Villes du menu clic droit du module météo (géocodées par weather.sh).
        La ville active est persistée hors du store et sert aussi de lieu au
        night light (wlsunset-geo.sh).
      '';
    };

    volumePresets = lib.mkOption {
      type = lib.types.listOf lib.types.int;
      default = [
        10
        25
        50
        75
        100
      ];
      description = "Niveaux de volume (%) proposés dans le menu clic droit.";
    };

    # Signaux RTMIN qui réveillent les modules custom (`signal` côté waybar,
    # `pkill -RTMIN+N waybar` côté scripts). Une seule table : les scripts
    # (luminosité, vpn-alert, météo) les reçoivent d'ici.
    signals = lib.mkOption {
      type = lib.types.attrsOf lib.types.int;
      readOnly = true;
      default = {
        weather = 8;
        backlight = 9;
        vpn = 10;
      };
      description = "Signaux RTMIN des modules custom de waybar.";
    };

    # Commande Nix-side « réveille le module X » (clics, menus).
    refresh = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      default = lib.mapAttrs (
        _: sig: "${pkgs.procps}/bin/pkill -RTMIN+${toString sig} waybar"
      ) cfg.signals;
      description = "Commandes `pkill -RTMIN+N waybar` par module, tirées de `signals`.";
    };

    backlightPresets = lib.mkOption {
      type = lib.types.listOf lib.types.int;
      default = [
        1
        25
        50
        75
        100
      ];
      description = "Niveaux de luminosité (%) proposés dans le menu clic droit.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Style maison (palette Stylix) pour coller à l'ancienne barre.
    stylix.targets.waybar.enable = false;

    # CLI pratiques (les scripts épinglent leurs deps, cf. ./scripts.nix).
    # playerctl vient du module sway.
    home.packages = [
      pkgs.curl
      pkgs.jq
    ];

    home.file = lib.mapAttrs' (
      name: m: lib.nameValuePair ".config/waybar/menus/${name}.xml" { text = m.xml; }
    ) menus;

    programs.waybar = {
      enable = true;
      systemd.enable = true;

      settings.mainBar = {
        layer = "top";
        position = "top";
        spacing = 4;

        modules-left = [ "sway/workspaces" ];
        modules-center = [ ];
        modules-right = [
          "custom/nowplaying"
          "custom/bluetooth"
          "network"
          "custom/vpn"
          "custom/resources"
          "custom/backlight"
          "wireplumber"
          "custom/swaync"
          "custom/disk"
          "custom/battery"
          "custom/weather"
          "clock"
          "tray"
        ];

        "sway/workspaces" = {
          disable-scroll = false;
          format = "{name}";
        };

        "custom/nowplaying" = {
          exec = "${scriptDir}/nowplaying.sh";
          # Piloté par événements (playerctl --follow), pas d'interval : relance
          # juste le flux continu s'il s'arrête.
          restart-interval = 1;
          tooltip = false;
          on-click = "${playerctl} -p spotify play-pause";
          on-scroll-up = "${playerctl} -p spotify next";
          on-scroll-down = "${playerctl} -p spotify previous";
        };

        "custom/bluetooth" = {
          exec = "${scriptDir}/bluetooth.sh";
          interval = 5;
          return-type = "json";
        }
        // clickIf "windowManager.sway.pickers.bluetooth" "bluetooth";

        network = {
          interval = 5;
          format-wifi = labeled "f05a9" "{essid} : {signalStrength}%";
          format-ethernet = labeled "f05a9" "{ifname}";
          format-disconnected = labeled "f05a9" "Off";
          tooltip-format = "{ifname} {ipaddr}";
        }
        // clickIf "windowManager.sway.pickers.wifi" "wifi";

        # Juste après le réseau : c'est le même sujet, et l'un se lit à la
        # lumière de l'autre — « connecté au WiFi du café, tunnel actif ».
        #
        # Le tunnel démarre au boot et n'est plus jamais coupé à la main, donc ce
        # module ne sert pas à savoir qu'on l'a activé, mais à voir tout de suite
        # qu'il ne répond plus. D'où l'intervalle court, et l'état « ? » distinct
        # de « Off ».
        #
        # La sonde elle-même est faite par vpn-alert toutes les 15 s, qui
        # publie l'état et réveille ce module par signal (une seule connexion
        # TCP au lieu de deux). Interval long = filet sans client VPN.
        "custom/vpn" = {
          exec = "${scriptDir}/vpn.sh";
          interval = 60;
          signal = cfg.signals.vpn;
          return-type = "json";
        };

        "custom/resources" = {
          exec = "${scriptDir}/resources.sh";
          # Flux continu (une ligne toutes les 3 s, cf. le script), pas
          # d'interval ; relancé seulement s'il s'arrête.
          restart-interval = 1;
          return-type = "json";
          on-click = myLib.desktop.mkTerminalCmd {
            inherit config;
            exec = btop;
          };
        };

        "custom/backlight" = {
          exec = "${scriptDir}/backlight.sh";
          # Rafraîchi par signal à chaque changement (`brightness` : touches
          # clavier, molette et menu ici ; night light). Relecture lente en
          # filet, pour un changement fait par un autre moyen.
          interval = 60;
          signal = cfg.signals.backlight;
          return-type = "json";
          format = "{icon}   {text}";
          format-icons = {
            on = mkIcon "f0594"; # md-weather-night : night light actif
            off = mkIcon "f00e0"; # md-brightness : night light off
          };
          on-click = nightlightToggle;
          on-scroll-up = "${brightness} up";
          on-scroll-down = "${brightness} down";
        }
        // withMenu "backlight";

        wireplumber =
          volScroll
          // {
            format = "{icon}  {volume}%";
            format-muted = "${mkIcon "f075f"}  {volume}%"; # md-volume-mute
            format-icons = [ (mkIcon "f057e") ]; # md-volume-high (toujours)
            on-click = volume.mute;
          }
          // withMenu "volume";

        "custom/swaync" =
          swayncBase
          // {
            format = "{icon}  {text}";
            format-icons = {
              notification = bell;
              none = bell;
              "dnd-notification" = bellOff;
              "dnd-none" = bellOff;
              "inhibited-notification" = bell;
              "inhibited-none" = bell;
              "dnd-inhibited-notification" = bellOff;
              "dnd-inhibited-none" = bellOff;
              default = bell;
            };
            on-click = "${swaync} -t -sw";
          }
          // withMenu "notifications";

        "custom/disk" = {
          exec = "${scriptDir}/disk.sh";
          interval = 30;
          return-type = "json";
        }
        // lib.optionalAttrs cfg.thunarFloat.enable {
          on-click = lib.getExe cfg.thunarFloat.package;
        };

        # Module custom (pas le natif) : ajoute profil d'alimentation et
        # régime des ventilateurs, impossibles avec le tooltip-format figé natif.
        "custom/battery" = {
          exec = "${scriptDir}/battery.sh";
          interval = 10; # profil/ventilo bougent plus vite que le niveau
          return-type = "json";
        }
        // clickIf "tui.lgControl" "lg-control";

        # Le script émet une catégorie dans "alt", mappée ici sur l'icône.
        "custom/weather" = {
          exec = "${scriptDir}/weather.sh";
          interval = 900; # 15 min : la météo bouge lentement, on ménage l'API
          signal = cfg.signals.weather;
          # Défaut exec-on-event = true relancerait weather.sh (requête réseau)
          # après CHAQUE événement souris, dont l'ouverture du menu au clic droit.
          exec-on-event = false;
          return-type = "json";
          format = "{icon}  {text}";
          on-click = weatherWake;
          format-icons = {
            clear-day = mkIcon "f0599"; # md-weather-sunny
            clear-night = mkIcon "f0594"; # md-weather-night
            partly-day = mkIcon "f0595"; # md-weather-partly-cloudy
            partly-night = mkIcon "f0f31"; # md-weather-night-partly-cloudy
            cloudy = mkIcon "f0590"; # md-weather-cloudy
            fog = mkIcon "f0591"; # md-weather-fog
            rain-light = mkIcon "f0597"; # md-weather-rainy
            rain = mkIcon "f0596"; # md-weather-pouring
            sleet = mkIcon "f067f"; # md-weather-snowy-rainy
            snow = mkIcon "f0598"; # md-weather-snowy
            snow-heavy = mkIcon "f0f36"; # md-weather-snowy-heavy
            hail = mkIcon "f0592"; # md-weather-hail
            thunder = mkIcon "f067e"; # md-weather-lightning-rainy
            offline = mkIcon "f0f2f"; # md-weather-cloudy-alert
          };
        }
        // withMenu "weather";

        clock = {
          format = labeled "f0e8f" "{:%a %d-%m-%Y %H:%M}"; # md-calendar-clock
          tooltip-format = "<tt>{calendar}</tt>";
        }
        // clickIf "tui.calendar" "calendar";

        tray = {
          icon-size = 16;
          spacing = 8;
        };
      };

      inherit style;
    };
  };
}
