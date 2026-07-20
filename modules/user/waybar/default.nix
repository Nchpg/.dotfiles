{ config, lib, ... }:

# Barre de la session sway (SEULE barre du dépôt : sway n'émet plus aucun
# bloc `bar {}` natif). Blocs cliquables via les launchers
# ~/.config/sway/launchers/*, fournis par wifi-picker, volume-mixer,
# bluetooth-picker, lg-control et calendar-tui.
let
  cfg = config.userSettings.waybar;
  inherit (cfg) pkgs;

  c = config.lib.stylix.colors.withHashtag;
  font = config.stylix.fonts.sansSerif.name;
  # Nerd Font (glyphes des icônes) + emoji en dernier recours.
  nerdFont = config.stylix.fonts.monospace.name;
  emojiFont = config.stylix.fonts.emoji.name;
  fontSize = toString config.stylix.fonts.sizes.desktop;

  home = config.home.homeDirectory;
  launcher = name: "${home}/.config/sway/launchers/${name}";

  # Câblé UNIQUEMENT si le module est activé pour le user, sinon pas
  # d'attribut on-click du tout (bloc affiché, clic inactif) : rend la barre
  # composable pour un user minimal (guest).
  clickIf =
    module: name: lib.optionalAttrs config.userSettings.${module}.enable { on-click = launcher name; };

  # Codepoint hexa -> glyphe, BMP ou plan astral (icônes Material Design >
  # U+FFFF -> paire de substitution UTF-16). Évite de taper le glyphe en dur
  # (qui se ferait stripper).
  mkIcon =
    hex:
    let
      digits = {
        "0" = 0;
        "1" = 1;
        "2" = 2;
        "3" = 3;
        "4" = 4;
        "5" = 5;
        "6" = 6;
        "7" = 7;
        "8" = 8;
        "9" = 9;
        "a" = 10;
        "b" = 11;
        "c" = 12;
        "d" = 13;
        "e" = 14;
        "f" = 15;
      };
      toInt = s: lib.foldl (acc: ch: acc * 16 + digits.${lib.toLower ch}) 0 (lib.stringToCharacters s);
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

  # Référencés explicitement (clics) pour ne pas dépendre du PATH.
  playerctl = "${pkgs.playerctl}/bin/playerctl";
  brightnessctl = "${pkgs.brightnessctl}/bin/brightnessctl";
  wpctl = "${pkgs.wireplumber}/bin/wpctl";
  swaync = "${pkgs.swaynotificationcenter}/bin/swaync-client";
  systemctl = "${pkgs.systemd}/bin/systemctl";
  pkill = "${pkgs.procps}/bin/pkill";

  # alacritty exige `-e`, kitty/foot acceptent le programme directement.
  term = config.userSettings.terminal.default;
  termExec = prog: if term == "alacritty" then "${term} -e ${prog}" else "${term} ${prog}";
  # programs.btop (pas pkgs.btop, amont driver i915-only) : support GPU xe
  # (PR #1457) si activé côté user.
  btop = "${config.programs.btop.package}/bin/btop";
  thunar = "${pkgs.thunar}/bin/thunar";

  scriptDir = "${home}/.config/waybar/scripts";
  scriptNames = [
    "resources.sh"
    "bluetooth.sh"
    "nowplaying.sh"
    "disk.sh"
    "weather.sh"
    "backlight.sh"
    "wlsunset-geo.sh"
    "battery.sh"
  ];

  libSh = builtins.readFile ./scripts/lib.sh;

  # PATH préfixé par leurs binaires (store) : robuste si la session change de
  # PATH, celui-ci reste ajouté en repli pour le reste.
  scriptDeps = {
    "resources.sh" = [
      pkgs.coreutils
      pkgs.gawk
    ];
    "bluetooth.sh" = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.bluez
    ];
    "nowplaying.sh" = [
      pkgs.coreutils
      pkgs.playerctl
    ];
    # jq : lecture du JSON santé NVMe publié par nvme-health-export.
    "disk.sh" = [
      pkgs.coreutils
      pkgs.jq
    ];
    "weather.sh" = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
    ];
    "backlight.sh" = [
      pkgs.coreutils
      pkgs.brightnessctl
      pkgs.systemd
    ];
    "wlsunset-geo.sh" = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
      pkgs.wlsunset
    ];
    "battery.sh" = [
      pkgs.coreutils
      pkgs.power-profiles-daemon
    ];
  };

  # Shebang bash épinglé + PATH déterministe + lib.sh + corps du script (son
  # propre `#!/usr/bin/env bash` devient un simple commentaire en milieu de fichier).
  mkScript =
    name:
    ''
      #!${pkgs.bash}/bin/bash
      export PATH=${lib.makeBinPath scriptDeps.${name}}:$PATH
    ''
    + libSh
    + builtins.readFile (./scripts + "/${name}");

  # Commandes volume (wpctl), réutilisées par la molette, le clic et le menu.
  volUp = "${wpctl} set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+";
  volDown = "${wpctl} set-volume @DEFAULT_AUDIO_SINK@ 5%-";
  volMute = "${wpctl} set-mute @DEFAULT_AUDIO_SINK@ toggle";
  volScroll = {
    on-scroll-up = volUp;
    on-scroll-down = volDown;
  };
  # Ids GTK = vol<N>. Source unique = volumePresets : un menus/volume.xml
  # statique désynchronisait silencieusement les ids si surchargé.
  volPresets = cfg.volumePresets;
  volPresetActions = lib.listToAttrs (
    map (
      p: lib.nameValuePair "vol${toString p}" "${wpctl} set-volume @DEFAULT_AUDIO_SINK@ ${toString p}%"
    ) volPresets
  );
  volumeMenuXml = ''
    <?xml version="1.0" encoding="UTF-8"?>
    <!-- Généré depuis `volumePresets` dans modules/user/waybar/default.nix. -->
    <interface>
      <object class="GtkMenu" id="menu">
        <child>
          <object class="GtkMenuItem" id="mute">
            <property name="label">Mute / Unmute</property>
          </object>
        </child>
        <child>
          <object class="GtkSeparatorMenuItem" id="sep1"/>
        </child>
        <child>
          <object class="GtkMenuItem" id="mixer">
            <property name="label">Ouvrir le mixer</property>
          </object>
        </child>
        <child>
          <object class="GtkSeparatorMenuItem" id="sep2"/>
        </child>
  ''
  + lib.concatMapStrings (p: ''
    <child>
      <object class="GtkMenuItem" id="vol${toString p}">
        <property name="label">${toString p} %</property>
      </object>
    </child>
  '') volPresets
  + ''
        <child>
          <object class="GtkSeparatorMenuItem" id="sep3"/>
        </child>
        <child>
          <object class="GtkMenuItem" id="volup">
            <property name="label">Volume +5 %</property>
          </object>
        </child>
        <child>
          <object class="GtkMenuItem" id="voldown">
            <property name="label">Volume -5 %</property>
          </object>
        </child>
      </object>
    </interface>
  '';

  menuDir = "${home}/.config/waybar/menus";
  menuNames = [
    "notifications.xml"
  ];

  # Choix courant persisté hors du store (weather.sh), survit aux reboots.
  inherit (cfg) weatherCities;

  # Signal utilisé à la fois pour `signal` côté waybar ET le `pkill` des
  # actions de menu, pour rester cohérents.
  weatherSignal = 8;
  weatherWake = "${pkill} -RTMIN+${toString weatherSignal} waybar";

  # `\''${…}` = ${…} littéral dans le shell ; `$HOME` reste littéral aussi.
  weatherStateDir = "\${XDG_STATE_HOME:-$HOME/.local/state}/waybar";
  # Écrit la ville, réveille la météo, relance le night light s'il tourne
  # (no-op sinon) pour qu'il adopte les coords de la nouvelle ville.
  mkWeatherAction =
    city:
    "mkdir -p \"${weatherStateDir}\""
    + " && printf '%s' ${lib.escapeShellArg city} > \"${weatherStateDir}/weather-city\""
    + " && ${weatherWake}"
    + " && ${systemctl} --user try-restart wlsunset";
  weatherMenuActions = lib.listToAttrs (
    map (c: lib.nameValuePair c (mkWeatherAction c)) weatherCities
  );

  # Villes saisies librement par l'utilisateur : échappement XML minimal.
  escapeXml = lib.replaceStrings [ "&" "<" ">" "\"" "'" ] [ "&amp;" "&lt;" "&gt;" "&quot;" "&apos;" ];

  weatherMenuXml = ''
    <?xml version="1.0" encoding="UTF-8"?>
    <!-- Généré depuis `weatherCities` dans modules/user/waybar/default.nix. -->
    <interface>
      <object class="GtkMenu" id="menu">
  ''
  + lib.concatMapStrings (c: ''
    <child>
      <object class="GtkMenuItem" id="${escapeXml c}">
        <property name="label">${escapeXml c}</property>
      </object>
    </child>
  '') weatherCities
  + ''
      </object>
    </interface>
  '';

  # Réveille le module luminosité pour rafraîchir l'icône/le % (clic/molette).
  backlightSignal = 9;
  refreshBacklight = "${pkill} -RTMIN+${toString backlightSignal} waybar";
  # Le choix PERSISTE au reboot via un flag : couper pose le fichier, rallumer
  # le retire, ExecCondition dessus (sans flag, WantedBy graphical-session
  # relancerait systématiquement le service).
  nightlightOffFlag = "$HOME/.local/state/wlsunset-off";
  nightlightToggle =
    "if ${systemctl} --user is-active --quiet wlsunset;"
    + " then ${systemctl} --user stop wlsunset;"
    + " ${pkgs.coreutils}/bin/mkdir -p \"$HOME/.local/state\" && ${pkgs.coreutils}/bin/touch \"${nightlightOffFlag}\";"
    + " else ${pkgs.coreutils}/bin/rm -f \"${nightlightOffFlag}\"; ${systemctl} --user start wlsunset; fi;"
    + " ${refreshBacklight}";

  # Baisse plancher à 1 % et JAMAIS 0 % : lit le % courant et garde
  # max(1, %-5), comme brightness.sh côté bind clavier sway.
  backlightUp = "${brightnessctl} set 5%+; ${refreshBacklight}";
  backlightDown =
    "p=$(${brightnessctl} -m | ${pkgs.coreutils}/bin/cut -d, -f4 | ${pkgs.coreutils}/bin/tr -d '%');"
    + " n=$(( p - 5 )); n=$(( n < 1 ? 1 : n ));"
    + " ${brightnessctl} set \${n}%; ${refreshBacklight}";

  # Source unique = backlightPresets. Id GTK préfixé "pct" (pas de chiffre en
  # tête) ; "mode"/"inc"/"dec" reliés aux actions.
  inherit (cfg) backlightPresets;
  backlightMenuActions =
    lib.listToAttrs (
      map (
        p: lib.nameValuePair "pct${toString p}" "${brightnessctl} set ${toString p}%; ${refreshBacklight}"
      ) backlightPresets
    )
    // {
      mode = nightlightToggle;
      inc = backlightUp;
      dec = backlightDown;
    };
  backlightMenuXml = ''
    <?xml version="1.0" encoding="UTF-8"?>
    <!-- Généré depuis `backlightPresets` dans modules/user/waybar/default.nix. -->
    <interface>
      <object class="GtkMenu" id="menu">
        <child>
          <object class="GtkMenuItem" id="mode">
            <property name="label">Changer de mode (night light)</property>
          </object>
        </child>
        <child>
          <object class="GtkSeparatorMenuItem" id="sepMode"/>
        </child>
  ''
  + lib.concatMapStrings (p: ''
    <child>
      <object class="GtkMenuItem" id="pct${toString p}">
        <property name="label">${toString p} %</property>
      </object>
    </child>
  '') backlightPresets
  + ''
        <child>
          <object class="GtkSeparatorMenuItem" id="sepStep"/>
        </child>
        <child>
          <object class="GtkMenuItem" id="inc">
            <property name="label">+5 %</property>
          </object>
        </child>
        <child>
          <object class="GtkMenuItem" id="dec">
            <property name="label">−5 %</property>
          </object>
        </child>
      </object>
    </interface>
  '';

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
  options.userSettings.waybar = {
    # Suit sway par défaut. ATTENTION : pas de fallback, waybar.enable = false
    # donne une session sway SANS AUCUNE barre (choix légitime pour un user minimal).
    enable = lib.mkEnableOption "waybar (seule barre de la session sway)" // {
      default = config.userSettings.sway.enable;
    };

    pkgs = import ../../../lib/mk-pkgs-option.nix { inherit lib config; };

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

    # Lieu PAS en dur : wlsunset-geo.sh lit la ville/coords du cache météo, un
    # changement de ville météo change aussi le lieu du night light.
    systemd.user.services.wlsunset = {
      Unit = {
        Description = "wlsunset – température de couleur jour/nuit";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Install.WantedBy = [ "graphical-session.target" ];
      Service = {
        # Flag posé par nightlightToggle : condition échoue -> "skipped" (pas
        # failed), pas de relance au login si le night light a été coupé.
        ExecCondition = "${pkgs.coreutils}/bin/test ! -e %h/.local/state/wlsunset-off";
        ExecStart = "${scriptDir}/wlsunset-geo.sh";
        Restart = "on-failure";
      };
    };

    # Les scripts épinglent déjà leurs deps (scriptDeps/mkScript) : gardés ici
    # seulement comme CLI pratiques (playerctl pilote aussi Spotify).
    home.packages = [
      pkgs.playerctl
      pkgs.curl
      pkgs.jq
    ];

    home.file = lib.listToAttrs (
      (map (
        n:
        lib.nameValuePair ".config/waybar/scripts/${n}" {
          text = mkScript n;
          executable = true;
        }
      ) scriptNames)
      ++ (map (
        n:
        lib.nameValuePair ".config/waybar/menus/${n}" {
          source = ./menus + "/${n}";
        }
      ) menuNames)
      ++ [
        # Menus générés (cf. let), pas des fichiers source.
        (lib.nameValuePair ".config/waybar/menus/weather.xml" {
          text = weatherMenuXml;
        })
        (lib.nameValuePair ".config/waybar/menus/backlight.xml" {
          text = backlightMenuXml;
        })
        (lib.nameValuePair ".config/waybar/menus/volume.xml" {
          text = volumeMenuXml;
        })
      ]
    );

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
        // clickIf "bluetoothPicker" "bluetooth";

        network = {
          interval = 5;
          format-wifi = labeled "f05a9" "{essid} : {signalStrength}%";
          format-ethernet = labeled "f05a9" "{ifname}";
          format-disconnected = labeled "f05a9" "Off";
          tooltip-format = "{ifname} {ipaddr}";
        }
        // clickIf "wifiPicker" "wifi";

        "custom/resources" = {
          exec = "${scriptDir}/resources.sh";
          interval = 3; # moins de réveils/forks qu'à 2s, gain batterie
          return-type = "json";
          on-click = termExec btop;
        };

        "custom/backlight" = {
          exec = "${scriptDir}/backlight.sh";
          interval = 3; # filet pour capter les touches clavier de luminosité
          signal = backlightSignal;
          return-type = "json";
          format = "{icon}   {text}";
          format-icons = {
            on = mkIcon "f0594"; # md-weather-night : night light actif
            off = mkIcon "f00e0"; # md-brightness : night light off
          };
          on-click = nightlightToggle;
          on-scroll-up = backlightUp;
          on-scroll-down = backlightDown;
          menu = "on-click-right";
          menu-file = "${menuDir}/backlight.xml";
          menu-actions = backlightMenuActions;
        };

        wireplumber = volScroll // {
          format = "{icon}  {volume}%";
          format-muted = "${mkIcon "f075f"}  {volume}%"; # md-volume-mute
          format-icons = [ (mkIcon "f057e") ]; # md-volume-high (toujours)
          on-click = volMute;
          menu = "on-click-right";
          menu-file = "${menuDir}/volume.xml";
          menu-actions = {
            mute = volMute;
            volup = volUp;
            voldown = volDown;
          }
          // lib.optionalAttrs config.userSettings.volumeMixer.enable {
            mixer = launcher "volume-mixer";
          }
          // volPresetActions;
        };

        "custom/swaync" = swayncBase // {
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
          menu = "on-click-right";
          menu-file = "${menuDir}/notifications.xml";
          menu-actions = {
            dnd = "${swaync} -d -sw";
            panel = "${swaync} -t -sw";
          };
        };

        "custom/disk" = {
          exec = "${scriptDir}/disk.sh";
          interval = 30;
          return-type = "json";
          on-click = thunar;
        };

        # Module custom (pas le natif) : ajoute profil d'alimentation et
        # régime des ventilateurs, impossibles avec le tooltip-format figé natif.
        "custom/battery" = {
          exec = "${scriptDir}/battery.sh";
          interval = 10; # profil/ventilo bougent plus vite que le niveau
          return-type = "json";
        }
        // clickIf "lgControl" "lg-control";

        # Le script émet une catégorie dans "alt", mappée ici sur l'icône.
        "custom/weather" = {
          exec = "${scriptDir}/weather.sh";
          interval = 900; # 15 min : la météo bouge lentement, on ménage l'API
          signal = weatherSignal;
          # Défaut exec-on-event = true relancerait weather.sh (requête réseau)
          # après CHAQUE événement souris, dont l'ouverture du menu au clic droit.
          exec-on-event = false;
          return-type = "json";
          format = "{icon}  {text}";
          on-click = weatherWake;
          menu = "on-click-right";
          menu-file = "${menuDir}/weather.xml";
          menu-actions = weatherMenuActions;
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
        };

        clock = {
          format = labeled "f0e8f" "{:%a %d-%m-%Y %H:%M}"; # md-calendar-clock
          tooltip-format = "<tt>{calendar}</tt>";
        }
        // clickIf "calendarTui" "calendar";

        tray = {
          icon-size = 16;
          spacing = 8;
        };
      };

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
        /* bright-* (base24) : sur un thème base16, retombe sur la couleur
           normale (repli mkBase24), rendu inchangé. */
        #workspaces button.urgent {
          background: ${c.bright-red};
          color: ${c.base00};
        }

        /* Espacement des modules de droite (aère les icônes/texte) */
        .modules-right > widget > * {
          padding: 0 8px;
          margin: 2px 2px;
        }

        /* Un accent de couleur par module (base16 Stylix). */
        #custom-nowplaying { color: ${c.base0B}; }  /* vert    */
        #custom-bluetooth  { color: ${c.base0D}; }  /* bleu    */
        #network           { color: ${c.base0C}; }  /* cyan    */
        #custom-resources  { color: ${c.base0A}; }  /* jaune   */
        #custom-backlight  { color: ${c.base09}; }  /* orange (toujours, quel que soit l'état night light) */
        #wireplumber       { color: ${c.base0E}; }  /* magenta (icône + %) */
        #custom-swaync     { color: ${c.base0A}; }  /* jaune (cloche + nombre) */
        #custom-disk       { color: ${c.base0C}; }  /* cyan    */
        #custom-battery    { color: ${c.base0B}; }  /* vert    */
        #custom-weather    { color: ${c.base0C}; }  /* cyan : partiellement/défaut */
        #custom-weather.sunny  { color: ${c.base0A}; }  /* jaune : soleil / ciel clair  */
        #custom-weather.cloudy { color: ${c.base04}; }  /* gris neutre : couvert / brume */
        #custom-weather.rain   { color: ${c.base0D}; }  /* bleu : pluie / neige / orage  */
        #clock             { color: ${c.base05}; font-weight: bold; }

        #custom-battery.warning  { color: ${c.bright-yellow}; }
        #custom-battery.critical { color: ${c.bright-red}; }

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
