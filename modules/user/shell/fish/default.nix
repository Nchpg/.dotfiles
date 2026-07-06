{ config, lib, pkgs-unstable, ... }:

let
  cfg = config.userSettings.shell.fish;
in {
  options = {
    userSettings.shell.fish = {
      enable = lib.mkEnableOption "Enable  fish";
      pkgs = lib.mkOption {
        type = lib.types.pkgs;
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

        interactiveShellInit = builtins.concatStringsSep "\n" [
          ''
            set -a fish_function_path ${cfg.pkgs.fishPlugins.fzf-fish}/functions
            set -a fish_complete_path ${cfg.pkgs.fishPlugins.fzf-fish}/completions
          ''
          (builtins.readFile ../common)
          (builtins.readFile ./fzf_wrapper.fish)
          (builtins.readFile ./.fish)
        ];
    };

    home.packages = with pkgs-unstable; [
      fishPlugins.fzf-fish
    ];
  };
}
