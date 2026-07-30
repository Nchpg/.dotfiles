{ config, pkgs-stable, ... }:

let
  desktop = config.systemSettings.desktop.enable;
in
# Core du système : le reliquat sans module dédié. Le reste vit dans
# modules/system/<sujet>/.
{
  home-manager.backupFileExtension = "hm-backup";

  # Réutilise l'instance nixpkgs du flake (allowUnfree inclus) : plus rapide
  # à évaluer. Options nixpkgs.* à poser sur pkgs-stable dans flake.nix.
  nixpkgs.pkgs = pkgs-stable;

  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      # Caches binaires claude-code (pas de follows, cf. flake.nix) et
      # ros.cachix.org (nix-ros-overlay, sinon recompile ROS2 depuis les
      # sources). extra-* s'ajoute aux défauts, ne les remplace pas.
      extra-substituters = [
        "https://claude-code.cachix.org"
        "https://ros.cachix.org"
      ];
      extra-trusted-public-keys = [
        "claude-code.cachix.org-1:YeXf2aNu7UTX8Vwrze0za1WEDS+4DuI2kVeWEE4fsRk="
        "ros.cachix.org-1:dSyZxI8geDCJrwgvCOHDoAfOm5sV1wCPjBkKL+38Rvo="
      ];
    };
    # 100 % flake : plus de channels ni de NIX_PATH.
    channel.enable = false;

    # Jeton de lecture pour l'entrée `secrets`, qui vit dans un dépôt PRIVÉ
    # (cf. flake.nix). Sans lui, l'évaluation du flake échoue en 404.
    #
    # Par `!include` et non par `nix.settings.access-tokens` : cette dernière
    # écrit la valeur dans /etc/nix/nix.conf, lisible par tous les utilisateurs
    # de la machine. Le fichier inclus, lui, est en 0600 root.
    #
    # Et pas non plus dans /root/.config/nix/nix.conf, qui serait plus simple et
    # supprimerait la boucle d'amorçage décrite plus bas. Vérifié dans
    # systemd.exec(5) : `$HOME` n'est posé que pour les unités qui déclarent un
    # `User=`. `nixos-upgrade.service` tourne en root sans en déclarer, donc
    # cette unité ne lirait PAS ce fichier. Ça marcherait sous sudo et
    # échouerait la nuit, en silence, sur la seule chose qui doit tourner sans
    # nous. /etc/nix/nix.conf est lu quoi qu'il arrive.
    #
    # POSÉ À LA MAIN, une fois par machine, et il ne peut pas en être autrement :
    # c'est le jeton qui donne accès aux secrets, il ne peut donc pas venir des
    # secrets. Même catégorie que /var/lib/sops-nix/key.txt, un identifiant
    # d'amorçage.
    #
    #   sudo install -d -m 700 /var/lib/nix
    #   sudo sh -c 'umask 077; echo "access-tokens = github.com=github_pat_..." \
    #     > /var/lib/nix/access-tokens.conf'
    extraOptions = ''
      !include /var/lib/nix/access-tokens.conf
    '';
  };

  # Fichier créé vide s'il manque, pour que le `!include` ci-dessus ait toujours
  # une cible. Vérifié : nix ignore en silence un include absent ou illisible,
  # donc ce n'est pas indispensable, mais un fichier présent et vide donne un
  # échec plus lisible — « 404 sur l'entrée secrets » plutôt qu'un jeton
  # fantôme.
  #
  # 0600 root, sans concession à la commodité. La récupération d'une entrée de
  # flake se fait dans l'ÉVALUATEUR, donc dans le processus qui lance la
  # commande, pas dans le démon : ouvrir ce fichier au groupe `wheel` aurait
  # permis à un processus tournant sous ton compte de cloner le dépôt privé,
  # donc d'ARCHIVER les fichiers chiffrés. Il ne pourrait pas les déchiffrer, la
  # clé système restant en 0600 root, mais il rouvrirait le « récolter
  # maintenant, déchiffrer plus tard » qui est la raison même d'avoir sorti ces
  # valeurs du dépôt public.
  #
  # Ce que ça coûte : une commande nix lancée sous ton compte qui doit ALLER
  # CHERCHER l'entrée échoue en 404. `rebuild` n'est pas concerné, il passe par
  # sudo, et une fois l'entrée récupérée par root elle est dans le store
  # partagé, donc les évaluations suivantes fonctionnent sans jeton. La gêne se
  # limite au moment qui suit un changement de lock — que la commande `secrets`
  # fait justement passer par sudo.
  # Le RÉPERTOIRE doit rester traversable par tout le monde, et c'est le piège
  # de tout ce montage. Si un utilisateur ne peut pas traverser jusqu'au fichier
  # inclus, nix n'ignore pas l'include : il abandonne la TOTALITÉ de
  # /etc/nix/nix.conf. Plus de flakes, plus de substituters, `max-jobs = 1`, et
  # aucun message pour le dire. Vérifié en A/B sur le fichier réel.
  #
  # Un fichier illisible dans un répertoire traversable, lui, est bien toléré :
  # c'est ce qui permet de garder le jeton en 0600 root.
  systemd.tmpfiles.rules = [
    "d /var/lib/nix 0755 root root -"
    "f /var/lib/nix/access-tokens.conf 0600 root root"
  ];

  # Orphelins seulement, jamais les générations (pas de --delete-older-than) :
  # leur rétention est pilotée par genclean.
  nix.gc = {
    automatic = true;
    dates = "weekly";
  };

  nix.optimise.automatic = true;

  # Défaut NixOS = 10 % du fs (~19 Go ici, jamais atteint mais illimité de
  # fait). 500 Mo couvrent largement plusieurs semaines.
  # EXPIRE(option:services.journald.settings): migrer extraConfig vers cette option
  services.journald.extraConfig = "SystemMaxUse=500M";

  # nixos-help jamais utilisé, coûte à chaque rebuild. Man pages classiques
  # toujours actives.
  documentation.nixos.enable = false;

  # Couvre le matériel réel (iwlwifi, BT Intel, GPU). enableAllFirmware
  # n'ajoutait que de l'exotique hors sujet.
  hardware.enableRedistributableFirmware = true;

  # Défaut NixOS, explicite pour rester auditable.
  networking.firewall.enable = true;

  # Les quatre services ci-dessous suivent systemSettings.desktop.enable :
  # ils servent un poste de travail, pas une machine administrée en SSH.
  services.printing.enable = desktop;

  # mDNS / IPP Everywhere : sans ça CUPS ne voit que les imprimantes ajoutées
  # à la main. Seul de ces quatre à ouvrir un port (5353/udp).
  services.avahi = {
    enable = desktop;
    nssmdns4 = desktop;
  };

  # Utilisé par lg-control et le module batterie de waybar. Explicite : sinon
  # fourni seulement en dépendance cachée du module GNOME.
  services.power-profiles-daemon.enable = desktop;

  # LVFS, passif (rien ne se flashe sans fwupdmgr update manuel).
  services.fwupd.enable = desktop;

  # Binaires non-Nix (prebuilds npm, installeurs curl|sh...) cherchent leur
  # loader en dur à /lib64/ld-linux-x86-64.so.2, absent sur NixOS. nix-ld pose
  # un shim, passif tant qu'aucun binaire étranger ne tourne.
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs-stable; [
    stdenv.cc.cc.lib
    zlib
    openssl
  ];

  environment.systemPackages = with pkgs-stable; [ lm_sensors ];

  environment.sessionVariables = {
    # Apps Electron/Chromium (Discord, Spotify, VSCode...) natif Wayland,
    # sinon fallback X11 qui meurt si XWayland est cassé.
    NIXOS_OZONE_WL = "1";
    MOZ_ENABLE_WAYLAND = "1";
  };

  # stateVersion vit dans hosts/<host>/configuration.nix (valeur par machine).
}
