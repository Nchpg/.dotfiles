{ config, lib, ... }:

let
  cfg = config.userSettings.shell.bash;
in
{
  options = {
    userSettings.shell.bash = {
      enable = lib.mkEnableOption "Enable bash";
      pkgs = import ../../../../lib/mk-pkgs-option.nix { inherit lib config; };
    };
  };
  config = lib.mkIf cfg.enable {
    programs.bash = {
      enable = true;
      package = cfg.pkgs.bash;
      historyControl = [
        "ignoredups"
        "ignorespace"
      ];
      bashrcExtra = builtins.concatStringsSep "\n" [
        (builtins.readFile ../common)
        (builtins.readFile ../common-posix)
        config.userSettings.shell.devShellAliases
        (builtins.readFile ./.bashrc)
      ];
    };
  };
}
