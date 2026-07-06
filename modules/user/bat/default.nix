{ config, lib, ... }:

let
  cfg = config.userSettings.bat;
in
{
  options = {
    userSettings.bat = {
      pkgs = lib.mkOption {
        type = lib.types.pkgs;
        default = config.userSettings.defaultPkgs;
        description = "Pkgs to use";
      };
    };
  };

  config = {
    programs.bat = {
      enable = true;
      package = cfg.pkgs.bat;
      config.theme = lib.mkForce "gruvbox-dark";
    };

    home.packages = with cfg.pkgs; [
      bat-extras.batgrep
      bat-extras.batman
    ];
  };
}
