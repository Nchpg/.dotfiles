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

    xdg.configFile."yazi/theme.toml".text = ''
    [flavor]
    dark = "gruvbox-dark"
    '';

    xdg.configFile."yazi/flavors/gruvbox-dark.yazi".source = cfg.pkgs.fetchFromGitHub {
      owner = "bennyyip";
      repo = "gruvbox-dark.yazi";
      rev = "main";
      sha256 = "1x8gmkjl0a1n0wl5y2bpqy130z2837p25y20mj47qmacv028zrrm";
    };
  };
}