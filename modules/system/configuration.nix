{ pkgs-stable, ... }:

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
      # Cache binaire claude-code (pas de follows, cf. flake.nix). extra-*
      # s'ajoute aux défauts, ne les remplace pas.
      #
      # UNE CLÉ DE CONFIANCE EST UNE AUTORISATION DE SERVIR N'IMPORTE QUEL
      # chemin du store, pas seulement ceux du projet qui l'a motivée. Elle ne
      # se garde donc que tant que le projet est réellement utilisé :
      # ros.cachix.org a été retiré à ce titre, nix-ros-overlay ayant disparu
      # des inputs sans que la clé suive.
      extra-substituters = [
        "https://claude-code.cachix.org"
      ];
      extra-trusted-public-keys = [
        "claude-code.cachix.org-1:YeXf2aNu7UTX8Vwrze0za1WEDS+4DuI2kVeWEE4fsRk="
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
    # `./init.sh` le fait, et c'est la voie à suivre. À la main, si besoin —
    # noter le 0755 sur le RÉPERTOIRE, qui n'est pas une négligence mais la
    # condition pour que nix ne jette pas /etc/nix/nix.conf en entier ; c'est
    # expliqué plus bas, à la règle tmpfiles :
    #
    #   sudo install -d -m 755 /var/lib/nix
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

  # Services de bureau (impression, avahi, power-profiles, fwupd) : cf.
  # modules/system/desktop.

  # Binaires non-Nix (prebuilds npm, installeurs curl|sh...) cherchent leur
  # loader en dur à /lib64/ld-linux-x86-64.so.2, absent sur NixOS. nix-ld pose
  # un shim, passif tant qu'aucun binaire étranger ne tourne.
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs-stable; [
    stdenv.cc.cc.lib
    zlib
    openssl
    # Apps GUI Wayland/Vulkan lancées en direct (AppImages de la Craft App
    # Suite via leur .desktop, cf. modules/user/apps/artcraft) : sans elles,
    # échec `NoWaylandLib` au démarrage.
    wayland
    libxkbcommon
    vulkan-loader
    libGL
    # Sélecteur de fichiers (rfd) : passe par le portail via libdbus, sinon
    # retombe sur zenity, absent -> aucune fenêtre à l'ouverture de fichier.
    dbus
    # Son (FilmCraft, DeckCraft, EffectCraft, SoundCraft) : lié en dur, sans
    # elle l'app ne démarre même pas (libasound.so.2 introuvable).
    alsa-lib
    # X11, chargées à l'exécution (dlopen) : certaines apps n'ont QUE ce
    # backend (DeckCraft 0.5 : « XNotSupported ... libX11.so.6 », aucune
    # fenêtre) et passent alors par XWayland ; les autres s'en servent en repli
    # sans Wayland.
    libx11
    libxcursor
    libxi
    libxrandr
    libxcb
    libxext
    libxrender
    libxfixes
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
