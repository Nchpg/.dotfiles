{ config, lib, ... }:

{
  imports = (lib.optional (builtins.pathExists ./private.nix) ./private.nix);

  config = {
    systemSettings = {
      # uncomment to disable user password check
      # verify_all_users_have_passwd = false;

      users = [ 
        {
          name = "nchpg";
          isAdmin = true;
          allowDocker = true;
        }
        {
          name = "guest";
          isAdmin = false;
          allowDocker = false;
        }
      ];

      window-manager = {
        sway.enable = true;
        gnome.enable = true;
      };
    };
  };
}
