{ config, lib, pkgs-stable, pkgs-unstable, ... }:

let
  cfg = config.userSettings.yazi;
in {
  options = {
    userSettings.yazi = {
      enable = lib.mkEnableOption "Enable yazi";

      pkgs = lib.mkOption {
        type = lib.types.attrs;
        default = config.userSettings.defaultPkgs;
        description = "Pkgs to use";
      };
    };
  };
  config = lib.mkIf cfg.enable {

    programs.yazi = {
      enable = true;
      package = cfg.pkgs.yazi;
    };

    # Yazi thémé par Stylix : il utilise exactement la même palette base16 que
    # le shell (et suit le toggle dark/light). On NE met PAS de flavor manuel
    # ici, sinon il écrirait le même theme.toml → conflit avec Stylix.
    stylix.targets.yazi.enable = true;
  };
}