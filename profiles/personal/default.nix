{ ... }:

{
  config = {
    systemSettings = {
      stylix = {
        enable = true;
        darkTheme = "gruvbox-dark-custom";
        lightTheme = "gruvbox-light";
      };

      sops.keyOwner = "nchpg";

      users = [
        {
          name = "nchpg";
          isAdmin = true;
          allowDocker = true;
          allowLibvirt = true;
          shell = "fish";
        }
        {
          name = "guest";
          isAdmin = false;
          allowDocker = false;
        }
      ];

      windowManager = {
        sway.enable = true;
        gnome.enable = true;
      };

      virtualisation = {
        docker.enable = true;
        libvirt.enable = true;
      };
    };
  };
}
