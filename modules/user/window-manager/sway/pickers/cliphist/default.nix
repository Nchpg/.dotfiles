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
    # $mod+v repose sur rofi : message clair plutôt qu'un bind silencieusement cassé.
    assertions = [
      {
        assertion = config.userSettings.windowManager.sway.rofi.enable;
        message = "userSettings.windowManager.sway.pickers.cliphist requiert userSettings.windowManager.sway.rofi (le bind $mod+v ouvre l'historique dans rofi).";
      }
    ];

    services.cliphist.enable = true;

    # wl-copy dépend de CE module (bind ci-dessous) : sinon venait de
    # flameshot, et le désactiver cassait le bind.
    home.packages = [ cfg.pkgs.wl-clipboard ];

    # `cliphist decode` (pas `cut -f2-`) restitue le contenu réel : images et
    # multi-lignes inclus. Chemins store : indépendant du PATH de session.
    home.file.".config/sway/conf.d/cliphist.conf".text =
      let
        cliphist = lib.getExe cfg.pkgs.cliphist;
        rofi = lib.getExe config.programs.rofi.package;
        wl-copy = "${cfg.pkgs.wl-clipboard}/bin/wl-copy";
        # Police du thème (comme le lanceur rofi), en plus grand : on lit ici
        # du contenu, pas des noms d'applis.
        font = "${config.stylix.fonts.sansSerif.name} 16";
      in
      ''
        bindsym $mod+v exec ${cliphist} list | ${rofi} -dmenu -p "  Clipboard" -theme-str 'window { width: 700px; } * { font: "${font}"; } element-icon { size: 0px; }' | ${cliphist} decode | ${wl-copy}
      '';
  };
}
