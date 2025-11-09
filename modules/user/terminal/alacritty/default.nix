{ config, lib, pkgs-stable, pkgs-unstable, stylix, ... }:

let
  cfg = config.userSettings.terminal.alacritty;
in {
  options = {
    userSettings.terminal.alacritty = {
      enable = lib.mkEnableOption "Enable alacritty terminal";
      pkgs = lib.mkOption {
        type = lib.types.attrs;
        default = config.userSettings.defaultPkgs;
        description = "Pkgs to use";
      };
      shell = lib.mkOption {
        type = lib.types.str;
        default = config.userSettings.shell.default;
        description = "Shell to use";
      };
    };
  };
  config = lib.mkIf cfg.enable {
    programs.alacritty = {
      enable = true;
      package = cfg.pkgs.alacritty;

      settings = {
        terminal.shell.program = "${cfg.pkgs."${cfg.shell}"}/bin/${cfg.shell}";
      };
    };

    stylix.targets.alacritty.enable = true;
  };
}