{
  config,
  lib,
  pkgs-stable,
  ...
}:

{
  options = {
    userSettings = {
      defaultPkgs = lib.mkOption {
        type = lib.types.pkgs;
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
    programs.home-manager.enable = true;

    home.sessionVariables = {
      EDITOR = "vim";
      VISUAL = "vim";
      MY_FLAKE = "${config.home.homeDirectory}/.dotfiles";
    };

    home.stateVersion = lib.mkOptionDefault "25.05";
  };
}
