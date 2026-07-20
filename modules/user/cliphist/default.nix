{ config, lib, ... }:

let
  cfg = config.userSettings.cliphist;
in
{
  options.userSettings.cliphist = {
    enable = lib.mkEnableOption "gestionnaire d'historique du presse-papier (cliphist + rofi)";
    pkgs = import ../../../lib/mk-pkgs-option.nix { inherit lib config; };
  };

  config = lib.mkIf cfg.enable {
    # $mod+v repose sur rofi : message clair plutôt qu'un bind silencieusement cassé.
    assertions = [
      {
        assertion = config.userSettings.rofi.enable;
        message = "userSettings.cliphist requiert userSettings.rofi (le bind $mod+v ouvre l'historique dans rofi).";
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
      in
      ''
        bindsym $mod+v exec ${cliphist} list | ${rofi} -dmenu -p "  Clipboard" -theme-str 'window { width: 700px; } * { font: "sans 16"; } element-icon { size: 0px; }' | ${cliphist} decode | ${wl-copy}
      '';
  };
}
