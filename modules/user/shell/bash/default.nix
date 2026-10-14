{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.shell.bash;
in
{
  options = {
    userSettings.shell.bash = {
      enable = lib.mkEnableOption "Enable bash";
      pkgs = myLib.mkPkgsOption { inherit lib config; };
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
        (builtins.readFile ../common-posix)
        (builtins.readFile ./.bashrc)
      ];
    };
  };
}
