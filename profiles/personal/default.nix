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

      # AdGuard DNS : bloque pubs et pisteurs pour tout le système.
      network.privateDns = {
        hostname = "dns.adguard-dns.com";
        addresses = [
          "94.140.14.14"
          "94.140.15.15"
          "2a10:50c0::ad1:ff"
          "2a10:50c0::ad2:ff"
        ];
      };

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
