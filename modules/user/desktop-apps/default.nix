{ config, lib, ... }:

# Gatées par profil : root/guest n'ont aucune raison d'embarquer Discord.
let
  cfg = config.userSettings.desktopApps;
in
{
  options.userSettings.desktopApps = {
    enable = lib.mkEnableOption "applications desktop (discord, mpv, ...) et direnv";

    pkgs = import ../../../lib/mk-pkgs-option.nix { inherit lib config; };
  };

  config = lib.mkIf cfg.enable {
    home.packages = with cfg.pkgs; [
      discord
      pavucontrol
      mpv
      nbfc-linux
    ];

    programs.direnv.enable = true;
  };
}
