{ config, lib, pkgs-stable, pkgs-unstable, ... }:

let
  cfg = config.userSettings.defaultPkgs;
in {
  options = {
    userSettings = {
      defaultPkgs = lib.mkOption {
        type = lib.types.attrs;
        default = pkgs-stable;
        description = "Default pkgs to use";
      };
      user = lib.mkOption {
        type = lib.types.str;
        description = "Name of the user";
      };
    };
  };

  config = {
    # link home-manager with system users
    programs.home-manager.enable = true;

    home.sessionVariables = {
      EDITOR = "vim";
      VISUAL = "vim";
    };

    # This value determines the Home Manager release that your
    # configuration is compatible with. This helps avoid breakage
    # when a new Home Manager release introduces backwards
    # incompatible changes.
    #
    # You can update Home Manager without changing this value. See
    # the Home Manager release notes for a list of state version
    # changes in each release.
    home.stateVersion = "25.05";
  };
}
