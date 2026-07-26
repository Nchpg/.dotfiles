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
    # link home-manager with system users
    programs.home-manager.enable = true;

    home.sessionVariables = {
      EDITOR = "vim";
      VISUAL = "vim";
      # homeDirectory (pas /home/${user} en dur) : le home de root est /root.
      MY_FLAKE = "${config.home.homeDirectory}/.dotfiles";
    };

    home.stateVersion = lib.mkOptionDefault "25.05";
  };
}
