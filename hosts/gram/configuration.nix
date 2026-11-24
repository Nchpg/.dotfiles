{ lib, ... }:

{
  systemSettings.hardware = {
    intelGraphics = {
      enable = true;
      # thermald (DPTF) varie de ~12 W (chaud, en jeu) à 28 W (à froid) : à 12 W, Dolphin plafonne à ~1,4 GHz et
      # saccade. 20 W : 95 °C et bridage thermique.
      # 16 W : courses fluides (~3,3 GHz, 75-84 °C) mais menus à vidéo saccadés (cœur à ~1,5 GHz, bridage pl1).
      # 18 W : compromis retenu (mesures du 2026-11-23). Plafond, pas consommation : sans charge, rien ne change.
      # Plancher en performance-max seulement (lg-control, $mod+Shift+p) ; ailleurs, thermald seul.
      powerLimit = 18;
    };
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
