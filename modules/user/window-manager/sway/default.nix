{
  config,
  lib,
  osConfig,
  myLib,
  ...
}:

let
  cfg = config.userSettings.windowManager.sway;
  inherit (cfg) pkgs;

  templateContent = builtins.readFile ./sway-config/config.template;

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

  brightness = pkgs.writeShellApplication {
    name = "brightness";
    runtimeInputs = [
      pkgs.brightnessctl
      pkgs.procps
    ];
    runtimeEnv.WAYBAR_BACKLIGHT_SIGNAL = toString cfg.waybar.signals.backlight;
    text = builtins.readFile ./sway-config/brightness.sh;
  };
in
{
  options.userSettings.windowManager.sway = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = osConfig.systemSettings.windowManager.sway.enable;
      description = "Config sway de ce user (défaut : suit le sway système).";
    };

    pkgs = myLib.mkPkgsOption { inherit lib config; };

    volume = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      default = {
        up = "${wpctl} set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+";
        down = "${wpctl} set-volume @DEFAULT_AUDIO_SINK@ 5%-";
        mute = "${wpctl} set-mute @DEFAULT_AUDIO_SINK@ toggle";
        micMute = "${wpctl} set-mute @DEFAULT_AUDIO_SOURCE@ toggle";
        set = "${wpctl} set-volume @DEFAULT_AUDIO_SINK@";
      };
      description = "Commandes volume (wpctl) partagées par les binds sway et waybar.";
    };

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

    home.file.".config/sway/config".text = finalConfigContent;

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
      pkgs.brightnessctl
      pkgs.playerctl
    ];
  };
}
