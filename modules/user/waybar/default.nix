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
  inherit (cfg) pkgs;

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

  # Binaires référencés explicitement (clics) pour ne pas dépendre du PATH.
  playerctl = "${pkgs.playerctl}/bin/playerctl";
  brightnessctl = "${pkgs.brightnessctl}/bin/brightnessctl";
  wpctl = "${pkgs.wireplumber}/bin/wpctl";
  swaync = "${pkgs.swaynotificationcenter}/bin/swaync-client";
  systemctl = "${pkgs.systemd}/bin/systemctl";

  # Terminal de l'utilisateur (même convention que le module sway) : alacritty
  # exige `-e` pour lancer un programme, kitty/foot l'acceptent directement.
  term = config.userSettings.terminal.default;
  termExec = prog: if term == "alacritty" then "${term} -e ${prog}" else "${term} ${prog}";
  # btop configuré par l'utilisateur (programs.btop), donc avec le support GPU
  # Intel xe (PR #1457) si activé. NE PAS prendre `pkgs.btop` : c'est le btop
  # amont (driver i915 only), qui n'affiche PAS le GPU xe de cette machine.
  btop = "${config.programs.btop.package}/bin/btop";
  thunar = "${pkgs.thunar}/bin/thunar"; # gestionnaire de fichiers (GUI)

  # Scripts custom (logique reprise de sway-bar.sh), installés dans la conf
  # waybar puis exécutés par chemin absolu (cf. scriptDir).
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

  # Helpers JSON communs (json_escape/emit), inlinés en tête de chaque script.
  libSh = builtins.readFile ./scripts/lib.sh;

  # Dépendances runtime épinglées par script : on préfixe le PATH avec leurs
  # binaires (store), donc les scripts ne dépendent plus du PATH ambiant pour
  # leurs outils (robuste si la session change de PATH). Le PATH ambiant reste
  # ajouté en repli pour le reste. coreutils couvre cat/date/df/numfmt/nproc/...
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

  # Script final = shebang vers un bash épinglé + PATH déterministe + lib.sh +
  # corps du script source. (Le `#!/usr/bin/env bash` du corps devient un simple
  # commentaire une fois en milieu de fichier.)
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
  # Presets de volume du menu clic droit (saut direct). Ids GTK = vol<N> dans
  # menus/volume.xml ; chaque action fixe le volume absolu via wpctl.
  volPresets = cfg.volumePresets;
  volPresetActions = lib.listToAttrs (
    map (
      p: lib.nameValuePair "vol${toString p}" "${wpctl} set-volume @DEFAULT_AUDIO_SINK@ ${toString p}%"
    ) volPresets
  );

  # Menus GTK au clic droit : fichiers XML installés dans menuDir, chaque entrée
  # reliée à sa commande (menu-actions) par l'id du GtkMenuItem.
  menuDir = "${home}/.config/waybar/menus";
  menuNames = [
    "volume.xml"
    "notifications.xml"
  ];

  # Villes proposées au clic droit du module météo (option userSettings.waybar.
  # weatherCities). Source unique : le menu XML et les actions sont générés à
  # partir de cette liste. Le choix courant est lui persisté hors du store
  # (cf. weather.sh), donc il survit aux reboots et rebuilds.
  inherit (cfg) weatherCities;

  # Signal temps-réel qui réveille le module météo (relance weather.sh sans
  # attendre l'intervalle). Source unique : utilisé pour `signal` côté waybar ET
  # pour le `pkill` des actions de menu -> les deux restent forcément cohérents.
  weatherSignal = 8;
  weatherWake = "pkill -RTMIN+${toString weatherSignal} waybar";

  # Action de menu : écrit la ville dans l'état persistant puis réveille le
  # module pour un switch immédiat.
  # `\''${…}` = ${…} littéral dans le shell ; `$HOME` reste littéral aussi.
  weatherStateDir = "\${XDG_STATE_HOME:-$HOME/.local/state}/waybar";
  # Écrit la ville, réveille la météo, et relance le night light s'il tourne
  # (try-restart = no-op si wlsunset est coupé) pour qu'il adopte les coords de
  # la nouvelle ville. Le wrapper wlsunset-geo.sh géocode lui-même au besoin.
  mkWeatherAction =
    city:
    "mkdir -p \"${weatherStateDir}\""
    + " && printf '%s' '${city}' > \"${weatherStateDir}/weather-city\""
    + " && ${weatherWake}"
    + " && ${systemctl} --user try-restart wlsunset";
  # Le menu clic droit ne sert qu'à changer de ville : une action par ville.
  # (L'actualisation est passée au clic GAUCHE -> on-click = weatherWake.)
  weatherMenuActions = lib.listToAttrs (
    map (c: lib.nameValuePair c (mkWeatherAction c)) weatherCities
  );

  # Menu GTK généré : un GtkMenuItem par ville (id = label = nom de la ville,
  # relié à `weatherMenuActions` par cet id).
  weatherMenuXml = ''
    <?xml version="1.0" encoding="UTF-8"?>
    <!-- Généré depuis `weatherCities` dans modules/user/waybar/default.nix. -->
    <interface>
      <object class="GtkMenu" id="menu">
  ''
  + lib.concatMapStrings (c: ''
    <child>
      <object class="GtkMenuItem" id="${c}">
        <property name="label">${c}</property>
      </object>
    </child>
  '') weatherCities
  + ''
      </object>
    </interface>
  '';

  # Le night light (service wlsunset) est piloté depuis le module luminosité
  # (custom/backlight) : son icône reflète l'état on/off. Ce signal réveille ce
  # module pour rafraîchir l'icône/le % aussitôt (clic ou molette).
  backlightSignal = 9;
  refreshBacklight = "pkill -RTMIN+${toString backlightSignal} waybar";
  # Clic gauche : bascule le service wlsunset (start/stop) puis rafraîchit
  # l'icône. Le choix PERSISTE au reboot via un flag : couper pose le fichier,
  # rallumer le retire, et le service a un ExecCondition dessus — au login il
  # ne démarre que si le night light n'était pas coupé (sans flag, le
  # WantedBy graphical-session le relançait systématiquement).
  nightlightOffFlag = "$HOME/.local/state/wlsunset-off";
  nightlightToggle =
    "if ${systemctl} --user is-active --quiet wlsunset;"
    + " then ${systemctl} --user stop wlsunset;"
    + " ${pkgs.coreutils}/bin/mkdir -p \"$HOME/.local/state\" && ${pkgs.coreutils}/bin/touch \"${nightlightOffFlag}\";"
    + " else ${pkgs.coreutils}/bin/rm -f \"${nightlightOffFlag}\"; ${systemctl} --user start wlsunset; fi;"
    + " ${refreshBacklight}";

  # Pas de luminosité ±5 % (molette ET menu). La hausse plafonne d'elle-même à
  # 100 % (brightnessctl). La BAISSE plancher à 1 % et JAMAIS 0 % : on lit le %
  # courant (champ 4 du CSV `-m`) et on garde max(1, %−5), comme le bind clavier
  # sway (brightness.sh : son plus petit palier est 1, pas 0).
  backlightUp = "${brightnessctl} set 5%+; ${refreshBacklight}";
  backlightDown =
    "p=$(${brightnessctl} -m | ${pkgs.coreutils}/bin/cut -d, -f4 | ${pkgs.coreutils}/bin/tr -d '%');"
    + " n=$(( p - 5 )); n=$(( n < 1 ? 1 : n ));"
    + " ${brightnessctl} set \${n}%; ${refreshBacklight}";

  # Menu clic-droit du module luminosité, dans l'ordre : « Changer de mode »
  # (bascule night light), séparateur, presets de niveau (saut direct via
  # brightnessctl), séparateur, et le pas ±5 % (mêmes commandes que la molette,
  # baisse plancher à 1 %). Source unique = backlightPresets. Id GTK préfixé
  # "pct" (pas de chiffre en tête) ; "mode"/"inc"/"dec" reliés aux actions.
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
    enable = lib.mkEnableOption "waybar (remplace la swaybar native)";

    pkgs = lib.mkOption {
      type = lib.types.pkgs;
      default = config.userSettings.defaultPkgs;
      description = "Pkgs to use";
    };

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
    # On gère nous-mêmes le style (palette Stylix) pour coller à l'ancienne barre.
    stylix.targets.waybar.enable = false;

    # Night light : wlsunset réchauffe la température de couleur de l'écran le
    # soir/nuit (gamma wlroots) pour les yeux, automatiquement selon le soleil.
    # Démarré avec la session graphique ; piloté au clic depuis le module
    # luminosité (custom/backlight). Le lieu n'est PAS en dur : le wrapper
    # wlsunset-geo.sh lit la ville/coords du cache météo (cf. lib.sh) -> changer
    # de ville météo change aussi le lieu du night light. Températures : jour
    # 6500 K (neutre), nuit 3800 K (chaud). wlsunset rétablit le gamma à l'arrêt.
    systemd.user.services.wlsunset = {
      Unit = {
        Description = "wlsunset – température de couleur jour/nuit";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Install.WantedBy = [ "graphical-session.target" ];
      Service = {
        # Respecte le toggle de la barre (cf. nightlightToggle) : si le night
        # light a été coupé, le flag existe et la condition échoue → unit
        # « skipped » (pas failed), le service ne se relance pas au login.
        ExecCondition = "${pkgs.coreutils}/bin/test ! -e %h/.local/state/wlsunset-off";
        ExecStart = "${scriptDir}/wlsunset-geo.sh";
        Restart = "on-failure";
      };
    };

    # Les scripts épinglent eux-mêmes leurs dépendances dans leur PATH (cf.
    # scriptDeps / mkScript), donc ces paquets ne sont plus requis ICI par
    # waybar. On les garde uniquement comme CLI pratiques pour l'utilisateur
    # (playerctl pilote aussi Spotify via les on-click/on-scroll du module).
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
      ]
    );

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
          # Piloté par événements (playerctl --follow) : pas d'interval, on
          # relance juste le flux continu s'il s'arrête (redémarrage dbus, etc.).
          restart-interval = 1;
          tooltip = false;
          on-click = "${playerctl} -p spotify play-pause";
          on-scroll-up = "${playerctl} -p spotify next";
          on-scroll-down = "${playerctl} -p spotify previous";
        };

        "custom/bluetooth" = {
          exec = "${scriptDir}/bluetooth.sh";
          interval = 5;
          # Sortie JSON : barre = noms tronqués, tooltip = noms complets.
          return-type = "json";
          on-click = launcher "bluetooth";
        };

        network = {
          interval = 5;
          format-wifi = labeled "f05a9" "{essid} : {signalStrength}%";
          format-ethernet = labeled "f05a9" "{ifname}";
          format-disconnected = labeled "f05a9" "Off";
          tooltip-format = "{ifname} {ipaddr}";
          on-click = launcher "wifi";
        };

        "custom/resources" = {
          exec = "${scriptDir}/resources.sh";
          interval = 3; # 3 s plutôt que 2 : moins de réveils/forks, gain batterie
          # Sortie JSON : texte compact (inchangé) dans la barre + détail
          # RAM/CPU/GPU et charge système en tooltip.
          return-type = "json";
          on-click = termExec btop; # détail des process dans btop
        };

        # Luminosité (custom : le % vient de brightnessctl, l'icône reflète
        # l'état du night light). Molette = ±5 % (puis refresh du %), clic =
        # bascule le night light (wlsunset). Couleur fixe orange (cf. CSS).
        "custom/backlight" = {
          exec = "${scriptDir}/backlight.sh";
          interval = 3; # filet pour capter les touches clavier de luminosité
          signal = backlightSignal; # refresh immédiat au clic/molette
          return-type = "json";
          format = "{icon}   {text}";
          format-icons = {
            on = mkIcon "f0594"; # md-weather-night (lune) : night light actif
            off = mkIcon "f00e0"; # md-brightness (luminosité) : night light off
          };
          on-click = nightlightToggle;
          on-scroll-up = backlightUp;
          on-scroll-down = backlightDown; # plancher à 1 % (cf. backlightDown)
          menu = "on-click-right";
          menu-file = "${menuDir}/backlight.xml";
          menu-actions = backlightMenuActions;
        };

        # Volume (module unique -> tooltip stable). Clic gauche = mute, clic
        # droit = menu (mute / mixer / presets 10-100 % / +5 / -5), molette = volume.
        wireplumber = volScroll // {
          format = "{icon}  {volume}%";
          format-muted = "${mkIcon "f075f"}  {volume}%"; # md-volume-mute
          format-icons = [ (mkIcon "f057e") ]; # md-volume-high (toujours)
          on-click = volMute;
          menu = "on-click-right";
          menu-file = "${menuDir}/volume.xml";
          menu-actions = {
            mute = volMute; # toggle mute/unmute
            mixer = launcher "volume-mixer";
            volup = volUp;
            voldown = volDown;
          }
          // volPresetActions;
        };

        # Notifications (module unique -> tooltip stable) : cloche + nombre.
        # Clic gauche = toggle « ne pas déranger », clic droit = menu (DND / panneau).
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
          on-click = "${swaync} -t -sw"; # afficher le panneau de notifications
          menu = "on-click-right";
          menu-file = "${menuDir}/notifications.xml";
          menu-actions = {
            dnd = "${swaync} -d -sw"; # toggle ne pas déranger
            panel = "${swaync} -t -sw";
          };
        };

        "custom/disk" = {
          exec = "${scriptDir}/disk.sh";
          interval = 30;
          # Sortie JSON : texte compact + détail (utilisé / total / libre).
          return-type = "json";
          on-click = thunar; # ouvre le gestionnaire de fichiers
        };

        # Batterie (module custom via battery.sh). On a quitté le module natif
        # pour pouvoir afficher, en plus de %/temps/santé/cycles, le profil
        # d'alimentation et le régime des ventilateurs — infos impossibles avec
        # le tooltip-format figé du module natif. Icône, %, classe (couleur) et
        # tooltip sont entièrement produits par le script.
        "custom/battery" = {
          exec = "${scriptDir}/battery.sh";
          interval = 10; # profil/ventilo bougent plus vite que le niveau
          return-type = "json";
          on-click = launcher "lg-control";
        };

        # Météo (Open-Meteo via weather.sh). Le script émet une catégorie dans
        # "alt", mappée ici sur l'icône Material Design (jour/nuit inclus).
        "custom/weather" = {
          exec = "${scriptDir}/weather.sh";
          interval = 900; # 15 min : la météo bouge lentement, on ménage l'API
          signal = weatherSignal; # réveillé par le menu (cf. weatherWake) pour un switch immédiat
          # Sans ça, waybar re-exécute weather.sh après CHAQUE événement souris
          # (défaut exec-on-event = true) : ouvrir le menu au clic droit relançait
          # une requête réseau (la date « Maj » bougeait). On ne rafraîchit donc
          # que sur le signal (clic gauche = weatherWake, ou choix de ville).
          exec-on-event = false;
          return-type = "json";
          format = "{icon}  {text}";
          # Clic gauche : actualiser (réveille weather.sh -> requête réseau).
          on-click = weatherWake;
          # Clic droit : choisir la ville (menu généré depuis weatherCities).
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

        #custom-battery.warning  { color: ${c.base0A}; }
        #custom-battery.critical { color: ${c.base08}; }

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
