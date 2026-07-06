{ config, lib, ... }:

let
  cfg = config.userSettings.tig;

  # Couleurs 256 de la ligne de curseur et des titres : valeurs historiques en
  # dark (inchangées), équivalents inversés en light (avant, les valeurs
  # sombres restaient appliquées même en thème light).
  isDark = (config.userSettings.stylix.themeconfig.polarity or "dark") == "dark";
  cursorColors =
    if isDark then
      ''
        color cursor                        223         236

        color title-focus                   246         235
        color title-blur                    246         235
      ''
    else
      ''
        color cursor                        236         223

        color title-focus                   240         253
        color title-blur                    240         253
      '';
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
      ${cursorColors}
      bind generic D >sh -c "git show %(commit) | delta --paging always --side-by-side"

      bind generic v >sh -c "git show %(commit):%(file) | bat --color=always --paging=always --style=plain -n --pager 'less -c -R' --file-name \"%(file)\""

      bind generic <Esc>[1;5A move-up
      bind generic <Esc>[1;5B move-down
    '';
  };
}
