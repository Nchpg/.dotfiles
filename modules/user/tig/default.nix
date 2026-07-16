{ config, lib, ... }:

let
  cfg = config.userSettings.tig;
in
{
  options = {
    userSettings.tig = {
      enable = lib.mkEnableOption "Enable tig";

      pkgs = lib.mkOption {
        type = lib.types.pkgs;
        default = config.userSettings.defaultPkgs;
        description = "Pkgs to use";
      };
    };
  };
  config = lib.mkIf cfg.enable {

    home.packages = with cfg.pkgs; [
      tig
    ];

    home.file.".tigrc".text = ''
      # Couleurs héritées du TERMINAL (palette ANSI posée par stylix) au lieu
      # d'indices 256 en dur : suivent le thème et la polarité sans double jeu
      # dark/light à entretenir. cursor en vidéo inversée (lisible partout),
      # titres en gris « commentaire » (ANSI 8 = base03, prévu pour les deux
      # polarités par base16).
      color cursor                        default     default     reverse
      color title-focus                   8           default
      color title-blur                    8           default

      bind generic D >sh -c "git show %(commit) | delta --paging always --side-by-side"

      bind generic v >sh -c "git show %(commit):%(file) | bat --color=always --paging=always --style=plain -n --pager 'less -c -R' --file-name \"%(file)\""

      bind generic <Esc>[1;5A move-up
      bind generic <Esc>[1;5B move-down
    '';
  };
}
