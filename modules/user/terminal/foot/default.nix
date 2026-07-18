{ config, lib, ... }:

let
  cfg = config.userSettings.terminal.foot;
in
{
  options = {
    userSettings.terminal.foot = {
      enable = lib.mkEnableOption "Enable foot terminal";
      pkgs = import ../../../../lib/mk-pkgs-option.nix { inherit lib config; };
      shell = import ../../../../lib/mk-terminal-shell-option.nix { inherit lib config; };
    };
  };
  config = lib.mkIf cfg.enable {
    programs.foot = {
      enable = true;
      package = cfg.pkgs.foot;

      settings = {
        main = {
          shell = "${cfg.pkgs."${cfg.shell}"}/bin/${cfg.shell}";
        };
      };
    };

    stylix.targets.foot.enable = true;
  };
}
