{ lib, config, pkgs-stable, pkgs-unstable, stylix, ... }:

let
  cfg = config.userSettings.stylix;
  theme = import (../../../modules/themes + ("/" + cfg.theme));
in
{
  options = {
    userSettings.stylix = {
      enable = lib.mkEnableOption "Enable stylix theming";
      theme = lib.mkOption {
        default = "orichalcum";
        type = lib.types.enum (builtins.attrNames (lib.filterAttrs (name: type: type == "directory") (builtins.readDir ../../themes)));
        description = "Theme for stylix to use system wide. A list of themes can be found in the `themes` directory.";
      };
      themeconfig = lib.mkOption {
        default = {};
        type = lib.types.attrsOf lib.types.str;
        description = "Theme config";
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
      image = pkgs-stable.fetchurl {
        url = theme.backgroundUrl;
        sha256 = theme.backgroundSha256 or theme.backgroundUrlSha256;
      };
      base16Scheme = theme;
      fonts = {
        monospace.name = "monospace";
        sansSerif.name = "Inter";
        serif.name = "Noto Serif";
        emoji.name = "Noto Color Emoji";
        sizes = {
          terminal = 16;
          applications = 10;
          desktop = 10;
        };
      };
    };
  };
}