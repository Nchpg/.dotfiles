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

  # Binding Ctrl+Return → terminal dans tmux, seulement si tmux est activé.
  tmuxBind = lib.optionalString config.userSettings.tmux.enable "bindsym Control+Return exec ${tmuxLaunch}";

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
      ]
      [
        config.userSettings.terminal.default
        tmuxBind
        barBlock
        lockCmd
        wallpaperBg
      ]
      templateContent;

  swaymsgBin = "${cfg.pkgs.sway}/bin/swaymsg";
in
{
  config = lib.mkIf cfg.enable {
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
