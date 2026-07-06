{ config, lib, ... }:

# Applications desktop et confort dev, gatées par profil : root/guest n'ont
# aucune raison d'embarquer Discord dans leur closure. (Le strict minimum
# commun à tous reste dans modules/user/common.nix.)
let
  cfg = config.userSettings.desktopApps;
in
{
  options.userSettings.desktopApps = {
    enable = lib.mkEnableOption "applications desktop (discord, mpv, ...) et direnv";

    pkgs = lib.mkOption {
      type = lib.types.pkgs;
      default = config.userSettings.defaultPkgs;
      description = "Pkgs to use";
    };
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
