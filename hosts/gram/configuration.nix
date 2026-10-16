{ lib, ... }:

{
  systemSettings.hardware = {
    intelGraphics.enable = true;
    displaylink.enable = true;

    lgLaptop = {
      enable = true;
      batteryCareLimit = 80;
    };
  };

  systemSettings.storage.swap = {
    zram.enable = true;
    earlyoom.enable = true;
  };

  systemSettings.ollama.enable = true;

  # Par host : personal-think hériterait d'un tunnel vers lui-même.
  systemSettings.vpn.client = {
    enable = true;
    address = "10.8.0.3/32";
    endpoint = "vpn.nathanchampagne.com:51820";
    serverPublicKey = "TiMfrxraOEgdQgrIWgaXEidoej/H7SKtpC+d7Rm8u0c=";
    privateKeyKey = "wireguard/gram_private_key";

    # Même secret que le `presharedKeyKey` du peer `gram` côté serveur.
    presharedKeyKey = "wireguard/gram_preshared_key";

    # Pas `192.168.1.0/24` : préfixe du WiFi maison, wg-quick échouerait à ajouter la route.
    allowedIPs = [ "10.8.0.0/24" ];

    dns = [ ];

    autostart = true;
  };

  system.stateVersion = "25.05";

  home-manager.sharedModules = [ { home.stateVersion = lib.mkDefault "25.05"; } ];
}
