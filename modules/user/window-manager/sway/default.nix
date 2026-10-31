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

  # Pas de barre de titre en tiling ; celles du mode stack/tabbed suivent la palette.
  # smart_borders : aucune bordure quand une fenêtre est seule sur son workspace.
  appearance = ''
    default_border pixel 1
    default_floating_border pixel 1
    smart_borders on
    titlebar_padding 8 3
    titlebar_border_thickness 1
  ''
  + lib.optionalString config.userSettings.stylix.enable (
    let
      c = config.lib.stylix.colors.withHashtag;
    in
    ''
      font pango:${config.stylix.fonts.sansSerif.name} 10
      client.focused          ${c.base03} ${c.base02} ${c.base06} ${c.base03} ${c.base03}
      client.focused_inactive ${c.base01} ${c.base00} ${c.base04} ${c.base01} ${c.base01}
      client.unfocused        ${c.base01} ${c.base00} ${c.base03} ${c.base01} ${c.base01}
      client.urgent           ${c.base08} ${c.base08} ${c.base00} ${c.base08} ${c.base08}
    ''
  );

  finalConfigContent =
    lib.replaceStrings
      [
        "@terminal@"
        "@wallpaperBg@"
        "@sessionVars@"
        "@appearance@"
        "@focusOrWorkspace@"
      ]
      [
        config.userSettings.terminal.default
        wallpaperBg
        (lib.concatStringsSep " " osConfig.systemSettings.windowManager.sway.sessionVariables)
        appearance
        (lib.getExe focusOrWorkspace)
      ]
      templateContent;

  # mod+flèches gauche/droite : fenêtre voisine, puis workspace suivant au bord.
  focusOrWorkspace = pkgs.writeShellApplication {
    name = "focus-or-workspace";
    runtimeInputs = [
      pkgs.sway
      pkgs.jq
    ];
    text = builtins.readFile ./sway-config/focus-or-workspace.sh;
  };

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
