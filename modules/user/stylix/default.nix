{ lib, config, pkgs-stable, pkgs-unstable, stylix, systemSettings, ... }:

let
  cfg = config.userSettings.stylix;
  theme = import (../../../modules/themes + ("/" + cfg.theme));
in
{
  options = {
    userSettings.stylix = {
      enable = lib.mkEnableOption "Enable stylix theming";
      theme = lib.mkOption {
        # Par défaut, on suit le thème système (systemSettings.stylix.theme) :
        # ainsi basculer le thème système flippe aussi la session de l'user.
        # Un user peut toujours surcharger (cf. root / guest qui fixent le leur).
        default = systemSettings.stylix.theme;
        type = lib.types.enum (builtins.attrNames (lib.filterAttrs (name: type: type == "directory") (builtins.readDir ../../themes)));
        description = "Theme for stylix to use system wide. A list of themes can be found in the `themes` directory.";
      };
      themeconfig = lib.mkOption {
        default = {};
        type = lib.types.attrsOf lib.types.str;
        description = "Theme config";
      };
      pkgs = lib.mkOption {
        type = lib.types.attrs;
        default = config.userSettings.defaultPkgs;
        description = "Pkgs to use";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    userSettings.stylix.themeconfig = theme;
    stylix = {
      enable = true;
      autoEnable = false;
      targets = {
        gtk.enable = true;
        qt.enable = true;
        gnome.enable = true;
      };
      polarity = theme.polarity;
      image = cfg.pkgs.fetchurl {
        url = theme.backgroundUrl;
        sha256 = theme.backgroundSha256 or theme.backgroundUrlSha256;
      };
      base16Scheme = theme;

      #/!\ fonts must be installed in modules/system/configuration.nix fonts.fonts /!\
      fonts = {
        monospace = {
          name = "FiraCode Nerd Font";
          package = cfg.pkgs.nerd-fonts.fira-code;
        };
        serif = {
          name = "Fira Sans";
          package = cfg.pkgs.fira-sans;
        };
        sansSerif = {
          name = "Fira Sans";
          package = cfg.pkgs.fira-sans;
        };
        emoji = {
          name = "Twitter Color Emoji";
          package = cfg.pkgs.twitter-color-emoji;
        };
        sizes = {
          terminal = 16;
          applications = 10;
          desktop = 10;
        };
      };
    };
  };
}