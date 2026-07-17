{
  config,
  lib,
  osConfig,
  ...
}:

let
  cfg = osConfig.systemSettings.window-manager.sway;

  # Edit config template terminal
  templateContent = builtins.readFile ./sway-config/config.template;

  # Commande pour lancer le terminal directement dans tmux.
  # alacritty exige -e ; kitty et foot acceptent le programme directement.
  term = config.userSettings.terminal.default;
  # TMUX_TMPDIR aligné sur celui des shells (home-manager fixe $XDG_RUNTIME_DIR)
  # pour viser le même serveur tmux. sway exec passe par sh -c → $XDG_RUNTIME_DIR
  # est bien expansé, et il est toujours défini dans une session sway/wayland.
  tmuxCmd = "env TMUX_TMPDIR=$XDG_RUNTIME_DIR tmux new-session -A -s main";
  tmuxLaunch = if term == "alacritty" then "${term} -e ${tmuxCmd}" else "${term} ${tmuxCmd}";

  # Bind (ou bloc) émis seulement si le module user `opt` est activé — évite un
  # bind mort, ou un daemon lancé dans le vide, quand le programme ciblé n'est
  # pas installé pour ce user. Tous les lanceurs vers d'autres modules passent
  # par là (rofi/swaync/flameshot suivent sway par défaut, mais on gate quand
  # même au cas où ils seraient explicitement coupés).
  bindIf = opt: str: lib.optionalString config.userSettings.${opt}.enable str;

  # Ctrl+Return → terminal dans tmux, seulement si tmux est activé.
  tmuxBind = bindIf "tmux" "bindsym Control+Return exec ${tmuxLaunch}";

  # $mod+Shift+f → firefox. Pas de résolution du nom (contrairement à chrome) :
  # le binaire s'appelle toujours `firefox`, non substituable.
  firefoxBind = bindIf "firefox" "bindsym $mod+Shift+f exec firefox";

  # $mod+Shift+c → chrome. Nom de binaire résolu depuis le paquet (substituable :
  # google-chrome-stable / chromium / ungoogled) et non un chemin store, pour
  # que le PATH résolve le wrapper home-manager qui porte les flags Wayland.
  chromeBind = lib.optionalString config.userSettings.chrome.enable "bindsym $mod+Shift+c exec ${baseNameOf (lib.getExe config.userSettings.chrome.package)}";

  # $mod+d / XF86Search → lanceur d'apps rofi.
  menuBind = bindIf "rofi" "bindsym $mod+d exec $menu";
  searchBind = bindIf "rofi" "bindsym XF86Search exec $menu";

  # $mod+n → centre de notifications swaync (module notifications).
  swayncBind = bindIf "notifications" "bindsym $mod+n exec swaync-client -t -sw";

  # Capture d'écran flameshot (opt-in) : daemon au démarrage + binds
  # Print/Shift+Print + règles de fenêtre. grim/slurp/wl-copy sont fournis par
  # le module flameshot, donc tout le bloc est gaté sur lui.
  flameshotDaemon = bindIf "flameshot" "exec QT_QPA_PLATFORM=wayland flameshot";
  flameshotBinds = bindIf "flameshot" ''
    # Print : flameshot (capture via grim → éditeur : annoter, sauver, copier).
    # QT_QPA_PLATFORM=wayland : la copie passe par KSystemClipboard (wlr-data-
    # control), actif seulement en Wayland natif. QT_QPA_PLATFORMTHEME=
    # xdgdesktopportal : boîte « Save » via le sélecteur de fichiers GTK.
    bindsym Print exec QT_QPA_PLATFORM=wayland QT_QPA_PLATFORMTHEME=xdgdesktopportal flameshot gui
    # Shift+Print : sélection d'une zone → copie directe dans le presse-papier.
    bindsym Shift+Print exec grim -g "$(slurp -d)" - | wl-copy

    # L'overlay flameshot doit être flottant/sans bordure (sinon tilé et cassé).
    for_window [app_id="flameshot"] floating enable, border none, fullscreen disable
    for_window [class="flameshot"] floating enable, border none, fullscreen disable
  '';

  # Fond d'écran : l'image résolue par stylix (thème actif, ou surcharge
  # userSettings.stylix.wallpaper — cf. modules/themes). Avant, un PNG en dur
  # (~/.config/sway/wallpaper.png) court-circuitait stylix : le fond ne suivait
  # ni le thème ni la config. Si stylix est coupé pour ce user, pas de ligne bg.
  wallpaperBg = lib.optionalString (
    config.userSettings.stylix.enable && config.stylix.image != null
  ) "output * bg ${config.stylix.image} fill";

  # Barre : si waybar est activé (module dédié), il fournit sa propre barre via
  # systemd → on n'émet PAS de bloc `bar {}` natif (sinon deux barres). Sinon on
  # garde la swaybar maison (sway-bar.sh).
  useWaybar = config.userSettings.waybar.enable;
  swaybarBlock = ''
    bar {
        position top

        status_command bash ~/.config/sway/sway-bar.sh
        tray_output *
        tray_padding 4

        # Pas d'onglet de mode (ex. le "displays" rouge) affiché dans la barre.
        binding_mode_indicator no

        colors {
            statusline #ffffff
            background #323232
        }
    }'';
  barBlock = if useWaybar then "" else swaybarBlock;

  # Args swaylock partagés par le bind clavier (config.template, @lockCmd@) et
  # swayidle ci-dessous : une seule définition, plus de divergence possible
  # entre les deux si l'effet visuel (blur, couleurs) change un jour.
  lockArgs =
    "--screenshots --clock --indicator"
    + " --indicator-radius 150 --indicator-thickness 7 --effect-blur 7x5"
    + " --effect-vignette 0.5:0.5 --ring-color bb00cc --key-hl-color 880033"
    + " --line-color 00000000 --inside-color 00000088 --separator-color 00000000"
    + " --grace 2 --fade-in 1";
  swaylockBin = "${cfg.pkgs.swaylock-effects}/bin/swaylock";
  # Bind clavier : premier plan, sway garde la main sur l'event loop.
  lockCmd = "${swaylockBin} ${lockArgs}";
  # swayidle : -f (daemonize) requis, sinon le lock bloquerait l'événement
  # before-sleep (swayidle attend la fin de la commande avant de continuer).
  lockCmdDaemonized = "${swaylockBin} -f ${lockArgs}";

  finalConfigContent =
    lib.replaceStrings
      [
        "@terminal@"
        "@tmuxBind@"
        "@bar@"
        "@lockCmd@"
        "@wallpaperBg@"
        "@chromeBind@"
        "@firefoxBind@"
        "@menuBind@"
        "@searchBind@"
        "@swayncBind@"
        "@flameshotDaemon@"
        "@flameshotBinds@"
      ]
      [
        config.userSettings.terminal.default
        tmuxBind
        barBlock
        lockCmd
        wallpaperBg
        chromeBind
        firefoxBind
        menuBind
        searchBind
        swayncBind
        flameshotDaemon
        flameshotBinds
      ]
      templateContent;

  swaymsgBin = "${cfg.pkgs.sway}/bin/swaymsg";
in
{
  options.userSettings.sway = {
    # Gate PROPRE à ce user, indépendant de desktopApps (un window manager n'a
    # rien à voir avec « des apps desktop »). Défaut : suit le sway SYSTÈME —
    # tout user d'un host où sway est activé reçoit sa config, avec la barre
    # native en haut (sway-bar.sh, dépendances installées ci-dessous). Pour la
    # barre waybar + les binds rofi/flameshot, il suffit d'activer ces modules
    # dans le profil du user. Mettre false pour un user qui ne veut pas de
    # session sway (ex. root, cf. son profil).
    enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable;
      description = "Config sway de ce user (défaut : suit le sway système).";
    };
  };

  config = lib.mkIf config.userSettings.sway.enable {
    assertions = [
      {
        assertion = cfg.enable;
        message = "userSettings.sway requiert systemSettings.window-manager.sway (le compositor vient du système).";
      }
    ];

    home.file.".config/sway/config" = {
      text = finalConfigContent;
    };

    home.file.".config/sway/brightness.sh" = {
      source = ./sway-config/brightness.sh;
      executable = true;
    };

    home.file.".config/sway/sway-bar.sh" = {
      source = ./sway-config/sway-bar.sh;
      executable = true;
    };

    # Cible de session graphique pour l'intégration systemd. Démarrée au lancement
    # de sway (cf. config.template), elle active graphical-session.target via BindsTo,
    # ce qui démarre automatiquement les services Wayland liés (cliphist, etc.) et
    # les arrête proprement à la sortie de sway.
    systemd.user.targets.sway-session = {
      Unit = {
        Description = "sway compositor session";
        Documentation = [ "man:systemd.special(7)" ];
        BindsTo = [ "graphical-session.target" ];
        Wants = [ "graphical-session-pre.target" ];
        After = [ "graphical-session-pre.target" ];
      };
    };

    # Capture d'écran (flameshot + grim/slurp/wl-clipboard) : module dédié
    # modules/user/flameshot. Les binds Print/Shift+Print, le daemon et les
    # règles for_window restent dans sway-config/config.template.
    home.packages = with cfg.pkgs; [

      # Sway bar dependencies
      acpi # Power battery
      alsa-utils # Sound
      brightnessctl # Brightness (remplace `light`, retiré en nixpkgs 26.05)
      playerctl # Audio player

      # Lock screen
      swaylock-effects
    ];

    # Verrouillage automatique : swaylock après 10 min d'inactivité, écrans
    # éteints après 15 min (rallumés au premier input), et lock systématique
    # avant une mise en veille (sinon la session revient déverrouillée au
    # réveil). Le service est lié à graphical-session.target (démarré par
    # sway-session.target, cf. plus haut).
    services.swayidle = {
      enable = true;
      package = cfg.pkgs.swayidle;
      timeouts = [
        {
          timeout = 600;
          command = lockCmdDaemonized;
        }
        {
          timeout = 900;
          command = "${swaymsgBin} 'output * power off'";
          resumeCommand = "${swaymsgBin} 'output * power on'";
        }
      ];
      events."before-sleep" = lockCmdDaemonized;
    };

    # NB : pas de stylix.targets.sway ici — ce target ne thémise que
    # wayland.windowManager.sway (module home-manager), qu'on n'utilise pas :
    # la config est écrite en dur via home.file. Les couleurs de bordures
    # vivent dans sway-config/config.template (volontairement fixes).
  };
}
