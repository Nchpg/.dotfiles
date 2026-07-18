{ config, lib, ... }:

let
  cfg = config.userSettings.terminal.alacritty;
in
{
  options = {
    userSettings.terminal.alacritty = {
      enable = lib.mkEnableOption "Enable alacritty terminal";
      pkgs = import ../../../../lib/mk-pkgs-option.nix { inherit lib config; };
      shell = import ../../../../lib/mk-terminal-shell-option.nix { inherit lib config; };
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
