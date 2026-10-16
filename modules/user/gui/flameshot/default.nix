{
  config,
  lib,
  osConfig,
  myLib,
  ...
}:

let
  cfg = config.userSettings.gui.flameshot;

  # flameshot demande un plein écran sur UN output (sway compresse l'image) :
  # on attend puis on repasse en `fullscreen global`.
  flameshotGui = cfg.pkgs.writeShellApplication {
    name = "flameshot-gui";
    runtimeInputs = [
      cfg.package
      osConfig.programs.sway.package
      cfg.pkgs.jq
    ];
    text = myLib.desktop.swayWaitSh + ''
      QT_QPA_PLATFORM=wayland QT_QPA_PLATFORMTHEME=xdgdesktopportal flameshot gui &
      sway_wait 40 0.05 '.. | objects | select(.type == "con" and .name == "flameshot" and .fullscreen_mode == 1) | .id' >/dev/null \
        || exit 0
      exec swaymsg '[title="^flameshot$"] border none, fullscreen enable global'
    '';
  };
in
{
  options = {
    userSettings.gui.flameshot = {
      enable = lib.mkEnableOption "flameshot (capture d'écran, Wayland natif sous Sway)";
      pkgs = myLib.mkPkgsOption { inherit lib config; };
      package = lib.mkOption {
        type = lib.types.package;
        default = cfg.pkgs.flameshot.override { enableWlrSupport = true; };
        defaultText = "flameshot avec enableWlrSupport = true";
        description = "flameshot avec enableWlrSupport (sans ça, écran noir sous Sway).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = with cfg.pkgs; [
      cfg.package
      grim
      slurp
    ];

    home.file.".config/sway/conf.d/flameshot.conf" =
      lib.mkIf config.userSettings.windowManager.sway.enable
        {
          text =
            let
              grim = lib.getExe cfg.pkgs.grim;
              slurp = lib.getExe cfg.pkgs.slurp;
              wl-copy = "${cfg.pkgs.wl-clipboard}/bin/wl-copy";
            in
            ''
              exec QT_QPA_PLATFORM=wayland ${lib.getExe cfg.package}

              bindsym Print exec ${lib.getExe flameshotGui}
              bindsym Shift+Print exec ${grim} -g "$(${slurp} -d)" - | ${wl-copy}
            '';
        };

    # flameshot.ini ne tolère pas de commentaires
    home.file.".config/flameshot/flameshot.ini".source = ./flameshot.ini;
  };
}
