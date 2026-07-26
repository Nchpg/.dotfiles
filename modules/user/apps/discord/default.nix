{
  config,
  lib,
  myLib,
  ...
}:

# Gaté par profil : root/guest n'ont aucune raison d'embarquer Discord.
let
  cfg = config.userSettings.apps.discord;
in
{
  options.userSettings.apps.discord = {
    enable = lib.mkEnableOption "Discord";

    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.pkgs.discord ];
  };
}
