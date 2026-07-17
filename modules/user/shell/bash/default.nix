{ config, lib, ... }:

let
  cfg = config.userSettings.shell.bash;
in
{
  options = {
    userSettings.shell.bash = {
      enable = lib.mkEnableOption "Enable bash";
      pkgs = lib.mkOption {
        type = lib.types.pkgs;
        default = config.userSettings.defaultPkgs;
        description = "Pkgs to use";
      };
    };
  };
  config = lib.mkIf cfg.enable {
    programs.bash = {
      enable = true;
      package = cfg.pkgs.bash;
      bashrcExtra = builtins.concatStringsSep "\n" [
        (builtins.readFile ../common)
        (builtins.readFile ../common-posix)
        config.userSettings.shell.devShellAliases
        (builtins.readFile ./.bashrc)
      ];
    };
  };
}
