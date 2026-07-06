{
  config,
  lib,
  pkgs-unstable,
  ...
}:

let
  cfg = config.userSettings.shell.fish;
in
{
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

      interactiveShellInit = builtins.concatStringsSep "\n" [
        (builtins.readFile ../common)
        (builtins.readFile ./fzf_wrapper.fish)
        (builtins.readFile ./.fish)
      ];
    };

    # fzf-fish est chargé par l'autoload vendor de fish (le paquet n'installe
    # QUE share/fish/vendor_{functions,completions,conf}.d ; les anciens ajouts
    # manuels à fish_function_path pointaient vers des chemins inexistants).
    # unstable pour suivre le fzf unstable épinglé dans modules/user/shell.
    home.packages = with pkgs-unstable; [
      fishPlugins.fzf-fish
    ];
  };
}
