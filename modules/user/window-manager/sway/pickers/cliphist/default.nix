{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.windowManager.sway.pickers.cliphist;
in
{
  options.userSettings.windowManager.sway.pickers.cliphist = {
    enable = lib.mkEnableOption "gestionnaire d'historique du presse-papier (cliphist + rofi)";
    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.userSettings.windowManager.sway.rofi.enable;
        message = "userSettings.windowManager.sway.pickers.cliphist requiert userSettings.windowManager.sway.rofi (le bind $mod+v ouvre l'historique dans rofi).";
      }
    ];

    services.cliphist.enable = true;

    home.packages = [ cfg.pkgs.wl-clipboard ];

    home.file.".config/sway/conf.d/cliphist.conf".text =
      let
        cliphist = lib.getExe cfg.pkgs.cliphist;
        rofi = lib.getExe config.programs.rofi.package;
        wl-copy = "${cfg.pkgs.wl-clipboard}/bin/wl-copy";
        font = "${config.stylix.fonts.sansSerif.name} 16";
      in
      ''
        bindsym $mod+v exec ${cliphist} list | ${rofi} -dmenu -p "  Clipboard" -theme-str 'window { width: 700px; } * { font: "${font}"; } element-icon { size: 0px; }' | ${cliphist} decode | ${wl-copy}
      '';
  };
}
