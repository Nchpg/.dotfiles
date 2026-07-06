{ config, lib, ... }:

let
  cfg = config.userSettings.tig;
in {
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
      color cursor                        223         236

      color title-focus                   246         235
      color title-blur                    246         235

      bind generic D >sh -c "git show %(commit) | delta --paging always --side-by-side"

      bind generic v >sh -c "git show %(commit):%(file) | bat --color=always --paging=always --style=plain -n --pager 'less -c -R' --file-name \"%(file)\""

      bind generic <Esc>[1;5A move-up
      bind generic <Esc>[1;5B move-down
    '';
  };
}