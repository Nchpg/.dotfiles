{ config, lib, ... }:

let
  cfg = config.userSettings.cliphist;
in {
  options.userSettings.cliphist = {
    enable = lib.mkEnableOption "gestionnaire d'historique du presse-papier (cliphist + wofi)";
    pkgs = lib.mkOption {
      type = lib.types.attrs;
      default = config.userSettings.defaultPkgs;
      description = "Pkgs to use";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.pkgs.wofi ];

    # Daemon : surveille le presse-papier et stocke chaque entrée dans l'historique.
    services.cliphist.enable = true;

    # Raccourci sway : $mod+v ouvre l'historique dans wofi, la sélection est copiée.
    home.file.".config/sway/conf.d/cliphist.conf".text = ''
      bindsym $mod+v exec cliphist list | wofi --dmenu --prompt "Clipboard" | cliphist decode | wl-copy
    '';
  };
}
