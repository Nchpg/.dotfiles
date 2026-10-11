{ lib, ... }:

# Réglages matériel de gram (LG Gram 2024, Meteor Lake), importés par
# hosts/default.nix. hardware-configuration.nix est généré à part.
{
  systemSettings.hardware = {
    intelGraphics.enable = true;
    displaylink.enable = true; # dock Dell D3100

    lgLaptop = {
      enable = true;
      batteryCareLimit = 80;
    };
  };

  # Dimensionné sur la RAM de CE host, pas sur le profil : pas de partition
  # de swap sur gram, la pression mémoire est absorbée par zram et earlyoom
  # tue avant que le système ne parte en thrashing.
  systemSettings.storage.swap = {
    zram.enable = true;
    earlyoom.enable = true;
  };

  # Modèles locaux : dépend du GPU et de la RAM de la machine, pas de la
  # persona — un host plus léger sous le même profil ne doit pas l'hériter.
  systemSettings.ollama.enable = true;

  # Client du tunnel vers think. Ici et non dans le profil, pour la même raison
  # que ci-dessus : c'est CE portable qui voyage, et son adresse dans le tunnel
  # lui est propre. Sous `profiles/personal`, personal-think hériterait d'un
  # tunnel vers lui-même et de la même adresse.
  #
  # Monté au boot (`autostart` plus bas) : le tunnel ne transporte que
  # 10.8.0.0/24, sans détour du reste du trafic. Bascule à la main au besoin,
  #   sudo systemctl stop wg-quick-wg0
  #
  # Les deux résolveurs sont ceux de la maison, dans l'ordre : wg-quick remplace
  # le résolveur du système pendant que le tunnel est monté, ce qui fait que
  # `cloud.` répond l'adresse du LAN même depuis un café — donc que le client
  # Nextcloud contourne le portail au lieu d'échouer dessus.
  systemSettings.vpn.client = {
    enable = true;
    address = "10.8.0.3/32";
    endpoint = "vpn.nathanchampagne.com:51820";
    serverPublicKey = "TiMfrxraOEgdQgrIWgaXEidoej/H7SKtpC+d7Rm8u0c=";
    privateKeyKey = "wireguard/gram_private_key";

    # Même secret que le `presharedKeyKey` du peer `gram` côté serveur, les deux
    # machines déchiffrant le même fichier. À changer des deux côtés en même
    # temps, un décalage donnant une poignée de main qui échoue en boucle.
    presharedKeyKey = "wireguard/gram_preshared_key";

    # SEUL le réseau du tunnel y passe. Tout le reste — navigation, mises à
    # jour, le trafic ordinaire — sort par la connexion où la machine se trouve.
    # WireGuard route par destination et non par application, donc c'est ainsi
    # qu'on obtient un « VPN uniquement pour Nextcloud » : en ne laissant qu'une
    # seule destination dedans, l'adresse de think dans le tunnel.
    #
    # Pourquoi PAS `192.168.1.0/24` : à la maison, ce préfixe est déjà celui de
    # l'interface WiFi. wg-quick tenterait d'ajouter une route pour un réseau
    # déjà connecté, ce qui échoue — le tunnel casserait précisément là où on
    # veut qu'il tourne. `10.8.0.0/24` n'entre en concurrence avec rien.
    #
    # Contrepartie assumée : le tunnel ne donne accès qu'à think, pas au reste du
    # LAN. Et il ne chiffre plus le trafic ordinaire sur un WiFi public, ce que
    # faisait le tunnel complet.
    allowedIPs = [ "10.8.0.0/24" ];

    # Aucun résolveur poussé, à dessein : celui de la maison n'est plus routé
    # dans le tunnel, donc le pousser enverrait les requêtes dans le vide. Chaque
    # appareil garde le sien, et `cloud.vpn.…` résout partout par son
    # enregistrement public vers 10.8.0.1.
    dns = [ ];

    # Monté en permanence, ce qui est sans conséquence maintenant que le tunnel
    # ne transporte qu'un /24 : pas de détour du trafic, pas de coût de batterie,
    # et surtout aucun risque de couper internet si think est éteinte — seul
    # 10.8.0.0/24 devient injoignable, le reste continue.
    autostart = true;
  };

  # Release de la première installation de CE host : ne suit PAS les
  # upgrades, valeur par machine comme hardware-configuration.nix.
  system.stateVersion = "25.05";

  home-manager.sharedModules = [ { home.stateVersion = lib.mkDefault "25.05"; } ];
}
