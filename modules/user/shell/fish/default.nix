{ config, lib, pkgs-stable, pkgs-unstable, ... }:

let
  cfg = config.userSettings.shell.fish;
in {
  options = {
    userSettings.shell.fish = {
      enable = lib.mkEnableOption "Enable  fish";
      pkgs = lib.mkOption {
        type = lib.types.attrs;
        default = config.userSettings.defaultPkgs;
        description = "Pkgs to use";
      };
    };
  };
  config = lib.mkIf cfg.enable {
    programs.fish = {
        enable = true;
        package = cfg.pkgs.fish;

        shellInit = ''
          fish_add_path ${cfg.pkgs.fishPlugins.fzf-fish}/bin
        '';

        interactiveShellInit = ''
          set -a fish_function_path ${cfg.pkgs.fishPlugins.fzf-fish}/functions
          set -a fish_complete_path ${cfg.pkgs.fishPlugins.fzf-fish}/completions
        '' + (builtins.readFile ../common) + (builtins.readFile ./.fish) ;
    };

    home.packages = with cfg.pkgs; [
      fishPlugins.fzf-fish
    ];
  };
}
