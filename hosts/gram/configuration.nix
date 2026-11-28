{ lib, ... }:

{
  systemSettings.hardware = {
    intelGraphics = {
      enable = true;
      # thermald (DPTF) varie de ~12 W (chaud, en jeu) à 28 W (à froid) : à 12 W, Dolphin plafonne à ~1,4 GHz et
      # saccade. Sans plafond du processeur (2026-11-23) : 20 W montait à 95 °C, 18 W était le compromis.
      # Avec le processeur à 60 % (cpuMaxPerf), Dolphin en 3× + MSAA 2×, course de 3 tours (2026-11-28) : à 18 W,
      # thermald y descend en fin de course et le GPU, bridé, saccade ; à 20 W, GPU jamais bridé (~730 MHz, libre
      # un tiers du temps), 78 °C en moyenne, 85 °C au pire. Plafond, pas consommation : sans charge, rien ne change.
      # Plancher en mode gaming seulement (lg-control, $mod+Shift+p) ; ailleurs, thermald seul. Coque plus chaude.
      powerLimit = 20;
      # Gaming, Dolphin en 2× : sans plafond, le turbo montait à 97 °C, thermald coupait la PL1 jusqu'à 12 W et le
      # GPU tombait à 0-450 MHz. À 70 % (~3,1 GHz) : 73 °C en moyenne, PL1 tenue à 25 W, GPU jamais bridé, à 800 MHz
      # et libre la moitié du temps, son sans craquement. En 3× + MSAA 2×, sur une course de 3 tours : à 70 %, GPU
      # bridé 98 % du temps à 450 MHz, 89 °C au pire ; à 60 % (~2,7 GHz), bridé 46 % du temps à 600 MHz, 81 °C au
      # pire, fil d'émulation à 30 % en moyenne (42 % au pire) : encore large (mesures du 2026-11-27/28).
      cpuMaxPerf = 60;
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
