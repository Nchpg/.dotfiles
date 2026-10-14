{
  config,
  lib,
  osConfig,
  myLib,
  ...
}:

# Config sway de l'utilisateur : le squelette (sway-config/config.template)
# et les touches multimédia. Chaque module qui ajoute un bind ou un démon à
# la session (rofi, notifications, session, lock, flameshot, wf-recorder,
# tmux, navigateurs, pickers…) écrit son propre fragment
# ~/.config/sway/conf.d/<nom>.conf, inclus à la fin du squelette : activer
# un module suffit à câbler son bind, le couper le retire.
let
  cfg = config.userSettings.windowManager.sway;
  inherit (cfg) pkgs;

  templateContent = builtins.readFile ./sway-config/config.template;

  # Résolu par stylix (thème actif ou surcharge userSettings.stylix.wallpaper).
  # Pas de ligne bg si stylix est coupé pour ce user.
  wallpaperBg = lib.optionalString (
    config.userSettings.stylix.enable && config.stylix.image != null
  ) "output * bg ${config.stylix.image} fill";

  finalConfigContent =
    lib.replaceStrings
      [
        "@terminal@"
        "@wallpaperBg@"
        "@sessionVars@"
      ]
      [
        config.userSettings.terminal.default
        wallpaperBg
        (lib.concatStringsSep " " osConfig.systemSettings.windowManager.sway.sessionVariables)
      ]
      templateContent;

  wpctl = "${pkgs.wireplumber}/bin/wpctl";
  playerctl = "${pkgs.playerctl}/bin/playerctl";

  # Luminosité par paliers (cf. sway-config/brightness.sh), partagée avec la
  # molette et le menu de waybar.
  brightness = pkgs.writeShellApplication {
    name = "brightness";
    runtimeInputs = [
      pkgs.brightnessctl
      pkgs.procps # pkill
    ];
    runtimeEnv.WAYBAR_BACKLIGHT_SIGNAL = toString cfg.waybar.signals.backlight;
    text = builtins.readFile ./sway-config/brightness.sh;
  };
in
{
  options.userSettings.windowManager.sway = {
    # Suit le sway SYSTÈME par défaut : mettre false pour un user sans
    # session sway (ex. root, cf. son profil).
    enable = lib.mkOption {
      type = lib.types.bool;
      default = osConfig.systemSettings.windowManager.sway.enable;
      description = "Config sway de ce user (défaut : suit le sway système).";
    };

    pkgs = myLib.mkPkgsOption { inherit lib config; };

    # Commandes volume, définies UNE fois pour les touches clavier (ici) et la
    # barre (molette, clic, menu de waybar). Plafond 1.0 sur la hausse : sans
    # lui, les touches montaient au-delà de 100 % (saturation) alors que la
    # molette de waybar s'arrêtait à 100 %.
    volume = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      default = {
        up = "${wpctl} set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+";
        down = "${wpctl} set-volume @DEFAULT_AUDIO_SINK@ 5%-";
        mute = "${wpctl} set-mute @DEFAULT_AUDIO_SINK@ toggle";
        micMute = "${wpctl} set-mute @DEFAULT_AUDIO_SOURCE@ toggle";
        # Suivi d'un pourcentage : "${set} 50%".
        set = "${wpctl} set-volume @DEFAULT_AUDIO_SINK@";
      };
      description = "Commandes volume (wpctl) partagées par les binds sway et waybar.";
    };

    # Paquet plutôt que script en home.file : deps épinglées, shellcheck au
    # build, un seul comportement pour clavier et barre.
    brightness = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = brightness;
      description = "Commande `brightness up|down|set N` (paliers fins en bas de plage), partagée par sway et waybar.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = osConfig.systemSettings.windowManager.sway.enable;
        message = "userSettings.windowManager.sway requiert systemSettings.windowManager.sway (le compositor vient du système).";
      }
    ];

    home.file.".config/sway/config" = {
      text = finalConfigContent;
    };

    home.file.".config/sway/conf.d/media-keys.conf".text = ''
      bindsym XF86AudioRaiseVolume exec ${cfg.volume.up}
      bindsym XF86AudioLowerVolume exec ${cfg.volume.down}
      bindsym XF86AudioMute exec ${cfg.volume.mute}
      bindsym XF86AudioMicMute exec ${cfg.volume.micMute}
      bindsym XF86AudioPlay exec ${playerctl} play-pause
      bindsym XF86AudioNext exec ${playerctl} next
      bindsym XF86AudioPrev exec ${playerctl} previous

      bindsym XF86MonBrightnessDown exec ${lib.getExe brightness} down
      bindsym XF86MonBrightnessUp exec ${lib.getExe brightness} up
    '';

    # Démarrée au lancement de sway (config.template), active
    # graphical-session.target via BindsTo : démarre/arrête les services
    # Wayland liés (cliphist, etc.) avec la session.
    systemd.user.targets.sway-session = {
      Unit = {
        Description = "sway compositor session";
        Documentation = [ "man:systemd.special(7)" ];
        BindsTo = [ "graphical-session.target" ];
        Wants = [ "graphical-session-pre.target" ];
        After = [ "graphical-session-pre.target" ];
      };
    };

    home.packages = [
      pkgs.brightnessctl # remplace `light`, retiré en nixpkgs 26.05
      pkgs.playerctl # CLI, pilote aussi Spotify
    ];

    # Pas de stylix.targets.sway : ce target ne thémise que
    # wayland.windowManager.sway (module HM), qu'on n'utilise pas ici.
  };
}
