{ config, lib, ... }:

let
  cfg = config.userSettings.dev.direnv;
in
{
  options.userSettings.dev.direnv = {
    enable = lib.mkEnableOption "direnv (chargement auto d'environnements par dossier)";
  };

  config = lib.mkIf cfg.enable {
    programs.direnv.enable = true;
  };
}
