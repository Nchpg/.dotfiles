{ config, lib, ... }:

let
  cfg = config.userSettings.cliphist;
in
{
  options.userSettings.cliphist = {
    enable = lib.mkEnableOption "gestionnaire d'historique du presse-papier (cliphist + rofi)";
    pkgs = lib.mkOption {
      type = lib.types.pkgs;
      default = config.userSettings.defaultPkgs;
      description = "Pkgs to use";
    };
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

    # Raccourci sway : $mod+v ouvre l'historique dans rofi, la sélection est copiée.
    home.file.".config/sway/conf.d/cliphist.conf".text = ''
      bindsym $mod+v exec cliphist list | cut -f2- | rofi -dmenu -p "  Clipboard" -theme-str 'window { width: 700px; } * { font: "sans 16"; } element-icon { size: 0px; }' | wl-copy
    '';
  };
}
