{
  config,
  lib,
  myLib,
  ...
}:

let
  sway = config.userSettings.windowManager.sway;
  cfg = sway.waybar;
  inherit (cfg) pkgs;

  c = config.lib.stylix.colors.withHashtag;

  home = config.home.homeDirectory;
  launcher = name: "${home}/.config/sway/launchers/${name}";

  # Chemin inexistant = erreur d'éval : on-click seulement si le module est activé.
  clickIf =
    modulePath: name:
    let
      parts = lib.splitString "." modulePath ++ [ "enable" ];
    in
    lib.optionalAttrs
      (
        if lib.hasAttrByPath parts config.userSettings then
          lib.getAttrFromPath parts config.userSettings
        else
          throw "waybar : le chemin « userSettings.${modulePath}.enable » n'existe pas (module déplacé ou renommé ?). Corrige la chaîne à l'appelant."
      )
      {
        on-click = launcher name;
      };

  inherit (myLib.desktop) mkIcon;

  labeled = hex: text: "${mkIcon hex}   ${text}";

  playerctl = "${pkgs.playerctl}/bin/playerctl";
  swaync = "${pkgs.swaynotificationcenter}/bin/swaync-client";

  # programs.btop (pas pkgs.btop) : support GPU xe (PR #1457)
  btop = "${config.programs.btop.package}/bin/btop";

  inherit (cfg) scriptDir;

  inherit (sway) volume;
  volScroll = {
    on-scroll-up = volume.up;
    on-scroll-down = volume.down;
  };

  # Ids GTK sans chiffre en tête.
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

    weather = myLib.desktop.mkWaybarMenu (
      map (city: {
        id = city;
        label = city;
        action = "${scriptDir}/weather-city.sh ${lib.escapeShellArg city}";
      }) cfg.weatherCities
    );

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
  withMenu = name: {
    menu = "on-click-right";
    menu-file = "${menuDir}/${name}.xml";
    menu-actions = menus.${name}.actions;
  };

  brightness = lib.getExe sway.brightness;
  nightlightToggle = "${scriptDir}/nightlight.sh toggle";

  styleVars = {
    font = config.stylix.fonts.sansSerif.name;
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
    "base06"
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

  swayncBase = {
    exec = "${swaync} -swb";
    return-type = "json";
  };
  bell = mkIcon "f009a"; # md-bell
  bellOff = mkIcon "f009b"; # md-bell-off
in
{
  options.userSettings.windowManager.sway.waybar = {
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
      description = "Villes du menu clic droit de la météo ; la ville active sert aussi de lieu au night light.";
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
    stylix.targets.waybar.enable = false;

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
        height = 38;
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

        # Sonde faite par vpn-alert (signal) ; interval long = filet.
        "custom/vpn" = {
          exec = "${scriptDir}/vpn.sh";
          interval = 60;
          signal = cfg.signals.vpn;
          return-type = "json";
        };

        "custom/resources" = {
          exec = "${scriptDir}/resources.sh";
          restart-interval = 1;
          return-type = "json";
          on-click = myLib.desktop.mkTerminalCmd {
            inherit config;
            exec = btop;
          };
        };

        "custom/backlight" = {
          exec = "${scriptDir}/backlight.sh";
          interval = 60;
          signal = cfg.signals.backlight;
          return-type = "json";
          format = "{icon}   {text}";
          format-icons = {
            on = mkIcon "f0594"; # md-weather-night
            off = mkIcon "f00e0"; # md-brightness
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

        "custom/battery" = {
          exec = "${scriptDir}/battery.sh";
          interval = 10;
          return-type = "json";
        }
        // clickIf "tui.lgControl" "lg-control";

        "custom/weather" = {
          exec = "${scriptDir}/weather.sh";
          interval = 900;
          signal = cfg.signals.weather;
          # Sinon weather.sh (réseau) est relancé à chaque événement souris
          exec-on-event = false;
          return-type = "json";
          format = "{icon}  {text}";
          on-click = "${pkgs.procps}/bin/pkill -RTMIN+${toString cfg.signals.weather} waybar";
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
