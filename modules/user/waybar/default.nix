{ config, lib, ... }:

# Barre waybar reproduisant la swaybar maison (cf. modules/user/sway/sway-config
# /sway-bar.sh) : mêmes blocs, mêmes icônes, mêmes clics — plus le tray. Quand ce
# module est activé, le module Sway retire sa barre native (cf.
# modules/user/sway/default.nix, placeholder @bar@) pour ne pas avoir 2 barres.
#
# Les blocs cliquables réutilisent les mêmes launchers que la swaybar
# (~/.config/sway/launchers/*), fournis par les modules wifi-picker,
# volume-mixer, bluetooth-picker, lg-control et calendar-tui.
let
  cfg = config.userSettings.waybar;
  pkgs = cfg.pkgs;

  c = config.lib.stylix.colors.withHashtag;
  font = config.stylix.fonts.sansSerif.name;
  # Nerd Font (glyphes des icônes) + emoji en dernier recours.
  nerdFont = config.stylix.fonts.monospace.name;
  emojiFont = config.stylix.fonts.emoji.name;
  fontSize = toString config.stylix.fonts.sizes.desktop;

  home = config.home.homeDirectory;
  launcher = name: "${home}/.config/sway/launchers/${name}";

  # Glyphe Nerd Font depuis un codepoint hexa, BMP ou plan astral (les icônes
  # Material Design sont > U+FFFF -> paire de substitution UTF-16). Évite de
  # taper le glyphe en dur (qui se ferait stripper) ; fromJSON gère le \u.
  mkIcon = hex:
    let
      digits = {
        "0" = 0; "1" = 1; "2" = 2; "3" = 3; "4" = 4; "5" = 5; "6" = 6;
        "7" = 7; "8" = 8; "9" = 9; "a" = 10; "b" = 11; "c" = 12; "d" = 13;
        "e" = 14; "f" = 15;
      };
      toInt = s: lib.foldl (acc: ch: acc * 16 + digits.${lib.toLower ch}) 0
        (lib.stringToCharacters s);
      toHex4 = x: lib.toLower (lib.fixedWidthString 4 "0" (lib.toHexString x));
      n = toInt hex;
    in
    if n <= 65535 then
      builtins.fromJSON ''"\u${toHex4 n}"''
    else
      let
        v = n - 65536;
        hi = 55296 + (v / 1024);
        lo = 56320 + (v - (v / 1024) * 1024);
      in
      builtins.fromJSON ''"\u${toHex4 hi}\u${toHex4 lo}"'';

  # Icône suivie de l'espacement standard de la barre (3 espaces) avant le texte.
  labeled = hex: text: "${mkIcon hex}   ${text}";

  # Binaires référencés explicitement (clics) pour ne pas dépendre du PATH.
  playerctl = "${pkgs.playerctl}/bin/playerctl";
  brightnessctl = "${pkgs.brightnessctl}/bin/brightnessctl";
  wpctl = "${pkgs.wireplumber}/bin/wpctl";
  swaync = "${pkgs.swaynotificationcenter}/bin/swaync-client";

  # Scripts custom (logique reprise de sway-bar.sh), installés dans la conf
  # waybar puis exécutés par chemin absolu (cf. scriptDir).
  scriptDir = "${home}/.config/waybar/scripts";
  scriptNames = [ "resources.sh" "bluetooth.sh" "nowplaying.sh" "disk.sh" ];

  # Molette = volume, partagée par l'icône (mute) et le % (mixer).
  volScroll = {
    on-scroll-up = "${wpctl} set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+";
    on-scroll-down = "${wpctl} set-volume @DEFAULT_AUDIO_SINK@ 5%-";
  };

  # Base commune aux deux modules swaync (icône cloche + nombre).
  swayncBase = {
    exec = "${swaync} -swb";
    return-type = "json";
    tooltip = false;
  };
  bell = mkIcon "f009a"; # md-bell
  bellOff = mkIcon "f009b"; # md-bell-off
in {
  options.userSettings.waybar = {
    enable = lib.mkEnableOption "waybar (remplace la swaybar native)";

    pkgs = lib.mkOption {
      type = lib.types.attrs;
      default = config.userSettings.defaultPkgs;
      description = "Pkgs to use";
    };
  };

  config = lib.mkIf cfg.enable {
    # On gère nous-mêmes le style (palette Stylix) pour coller à l'ancienne barre.
    stylix.targets.waybar.enable = false;

    # playerctl : appelé depuis le PATH par nowplaying.sh (les autres outils des
    # scripts — bluetoothctl, top, free, df — viennent du système).
    home.packages = [ pkgs.playerctl ];

    home.file = lib.listToAttrs (map
      (n: lib.nameValuePair ".config/waybar/scripts/${n}" {
        source = ./scripts + "/${n}";
        executable = true;
      })
      scriptNames);

    programs.waybar = {
      enable = true;
      # Démarrée par systemd avec la session graphique (graphical-session.target,
      # activée par sway-session.target — cf. module sway).
      systemd.enable = true;

      settings.mainBar = {
        layer = "top";
        position = "top";
        spacing = 4;

        modules-left = [ "sway/workspaces" ];
        modules-center = [ ];
        # Même ordre que la swaybar (nowplaying ... datetime), tray en bout.
        modules-right = [
          "custom/nowplaying"
          "custom/bluetooth"
          "network"
          "custom/resources"
          "backlight"
          "wireplumber#icon"
          "wireplumber#pct"
          "custom/swaync"
          "custom/swayncount"
          "custom/disk"
          "battery"
          "clock"
          "tray"
        ];

        "sway/workspaces" = {
          disable-scroll = false;
          format = "{name}";
        };

        "custom/nowplaying" = {
          exec = "${scriptDir}/nowplaying.sh";
          interval = 2;
          tooltip = false;
          on-click = "${playerctl} -p spotify play-pause";
          on-scroll-up = "${playerctl} -p spotify next";
          on-scroll-down = "${playerctl} -p spotify previous";
        };

        "custom/bluetooth" = {
          exec = "${scriptDir}/bluetooth.sh";
          interval = 5;
          tooltip = false;
          on-click = launcher "bluetooth";
        };

        network = {
          interval = 5;
          format-wifi = labeled "f1eb" "{essid} : {signalStrength}";
          format-ethernet = labeled "f1eb" "{ifname}";
          format-disconnected = labeled "f1eb" "Off";
          tooltip-format = "{ifname} {ipaddr}";
          on-click = launcher "wifi";
        };

        "custom/resources" = {
          exec = "${scriptDir}/resources.sh";
          interval = 2;
          tooltip = false;
        };

        backlight = {
          format = labeled "f185" "{percent}%";
          on-scroll-up = "${brightnessctl} set 5%+";
          on-scroll-down = "${brightnessctl} set 5%-";
        };

        # Volume scindé : l'icône (clic = mute) et le % (clic = mixer, comme
        # mod+p). La molette (volScroll) règle le volume sur les deux.
        "wireplumber#icon" = volScroll // {
          format = mkIcon "f057e"; # md-volume-high
          format-muted = mkIcon "f075f"; # md-volume-mute (haut-parleur + croix)
          on-click = "${wpctl} set-mute @DEFAULT_AUDIO_SINK@ toggle";
        };
        "wireplumber#pct" = volScroll // {
          format = "{volume}%";
          format-muted = "{volume}%";
          on-click = launcher "volume-mixer";
        };

        # Cloche scindée : l'icône (clic = bascule DND) et le nombre (clic =
        # ouvre le panneau, comme mod+n).
        "custom/swaync" = swayncBase // {
          format = "{icon}";
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
          on-click = "${swaync} -d -sw";
        };
        "custom/swayncount" = swayncBase // {
          format = "{text}";
          on-click = "${swaync} -t -sw";
        };

        "custom/disk" = {
          exec = "${scriptDir}/disk.sh";
          interval = 30;
          tooltip = false;
        };

        battery = {
          interval = 30;
          states = { warning = 20; critical = 10; };
          format = labeled "f240" "{capacity}%"; # md/fa-battery
          format-charging = labeled "f0e7" "{capacity}%"; # éclair
          format-plugged = labeled "f0e7" "{capacity}%";
          format-full = labeled "f240" "{capacity}%";
          on-click = launcher "lg-control";
        };

        clock = {
          format = labeled "f073" "{:%a %d-%m-%Y %H:%M}"; # calendrier
          tooltip-format = "<tt>{calendar}</tt>";
          on-click = launcher "calendar";
        };

        tray = {
          icon-size = 16;
          spacing = 8;
        };
      };

      # Style : fond Stylix, texte adouci (base04), un accent de couleur par
      # module, et de l'espacement pour aérer. Tout en base16 (palette Stylix).
      style = ''
        * {
          font-family: "${font}", "${nerdFont}", "${emojiFont}";
          font-size: ${fontSize}pt;
          min-height: 0;
        }

        window#waybar {
          background: ${c.base00};
          color: ${c.base04};
        }

        /* Workspaces (numéros) à gauche : carrés (min-width ≈ hauteur via le
           padding vertical). On neutralise le chrome GTK par défaut
           (bordure/ombre/outline non thémés). */
        #workspaces {
          margin-left: 6px;
        }
        #workspaces button {
          padding: 3px 0;          /* hauteur ; min-width pour la largeur -> carré */
          margin: 2px 2px;
          min-width: 22px;
          border: none;
          border-radius: 4px;      /* mettre 0 pour des angles bien droits */
          box-shadow: none;
          background: ${c.base01};  /* fond inactif (un cran au-dessus du fond) */
          color: ${c.base04};       /* texte inactif adouci -> l'actif ressort */
          transition: background-color 0.15s ease, color 0.15s ease;
        }
        #workspaces button:hover {
          background: ${c.base02};
          color: ${c.base05};
        }
        #workspaces button.focused,
        #workspaces button.visible {
          background: ${c.base0D};   /* accent (bleu Stylix) pour l'actif */
          color: ${c.base00};
        }
        #workspaces button.urgent {
          background: ${c.base08};   /* rouge Stylix pour l'urgent */
          color: ${c.base00};
        }

        /* Espacement des modules de droite (aère les icônes/texte) */
        .modules-right > widget > * {
          padding: 0 8px;
          margin: 2px 2px;
        }

        /* Paires icône+valeur scindées (volume, cloche) : on resserre l'écart
           ENTRE les deux éléments, tout en gardant l'écart normal avec les
           modules voisins. */
        #wireplumber.icon,
        #custom-swaync {
          padding-right: 3px;
          margin-right: 0;
        }
        #wireplumber.pct,
        #custom-swayncount {
          padding-left: 1px;
          margin-left: 0;
        }

        /* Un accent de couleur par module (base16 Stylix). */
        #custom-nowplaying { color: ${c.base0B}; }  /* vert    */
        #custom-bluetooth  { color: ${c.base0D}; }  /* bleu    */
        #network           { color: ${c.base0C}; }  /* cyan    */
        #custom-resources  { color: ${c.base0A}; }  /* jaune   */
        #backlight         { color: ${c.base09}; }  /* orange  */
        #wireplumber       { color: ${c.base0E}; }  /* magenta (icône + %) */
        #custom-swaync,
        #custom-swayncount { color: ${c.base0A}; }  /* jaune (cloche + nombre) */
        #custom-disk       { color: ${c.base0C}; }  /* cyan    */
        #battery           { color: ${c.base0B}; }  /* vert    */
        #clock             { color: ${c.base05}; font-weight: bold; }

        #battery.warning  { color: ${c.base0A}; }
        #battery.critical { color: ${c.base08}; }

        #tray {
          padding: 0 8px;
        }

        tooltip {
          background: ${c.base01};
          border: 1px solid ${c.base03};
        }
        tooltip label {
          color: ${c.base05};
        }
      '';
    };
  };
}
