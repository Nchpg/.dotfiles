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
    # Le bind $mod+v repose sur rofi : on échoue à l'éval avec un message clair
    # plutôt qu'avec un raccourci silencieusement cassé.
    assertions = [
      {
        assertion = config.userSettings.rofi.enable;
        message = "userSettings.cliphist requiert userSettings.rofi (le bind $mod+v ouvre l'historique dans rofi).";
      }
    ];

    # Daemon : surveille le presse-papier et stocke chaque entrée dans l'historique.
    services.cliphist.enable = true;

    # wl-copy est une dépendance de CE module (le bind ci-dessous) : sans ça il
    # ne venait que de flameshot, et désactiver flameshot cassait le bind.
    home.packages = [ cfg.pkgs.wl-clipboard ];

    # Raccourci sway : $mod+v ouvre l'historique dans rofi, la sélection est
    # copiée. Le passage par `cliphist decode` (au lieu de l'ancien `cut -f2-`
    # qui jetait l'ID) restitue le contenu réel : images et multi-lignes
    # inclus. Binaires en chemins store : le bind ne dépend pas du PATH de la
    # session (même pattern que waybar).
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
