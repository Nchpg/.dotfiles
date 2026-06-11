{ config, lib, ... }:

{
  config = {
    systemSettings = {
      stylix = {
        enable = true;
        variant = "dark";                  # ← interrupteur dark / light
        darkTheme = "gruvbox-dark-custom";
        lightTheme = "gruvbox-light-hard";
      };

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
