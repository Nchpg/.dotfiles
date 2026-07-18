{ pkgs-stable, ... }:

# Core du système : Nix lui-même, firmware, et le petit reliquat qui n'a pas
# (encore) de module dédié. Tout le reste vit dans modules/system/<sujet>/ :
# boot, locale, network, audio, bluetooth, gdm, disks, fonts, swap, users,
# et les modules à option (intel-graphics, virtualisation, ollama, sway,
# gnome, stylix, lg-laptop) activés par le host ou le profil.
{
  home-manager.backupFileExtension = "hm-backup";

  # Réutilise l'instance nixpkgs du flake (allowUnfree inclus) au lieu d'en
  # instancier une nouvelle → évaluation plus rapide. Toute option nixpkgs.*
  # (config/overlays) serait ignorée : les poser sur pkgs-stable dans flake.nix.
  nixpkgs.pkgs = pkgs-stable;

  # Active Flake
  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      # Cache binaire de l'input claude-code (cf. flake.nix : pas de follows
      # pour garder les hashes de l'upstream → hit possible). Sans ces deux
      # lignes le hit n'était jamais effectif : Nix n'interroge que
      # cache.nixos.org par défaut, et claude-code se rebuildait localement
      # à chaque bump. `extra-*` = ajout aux défauts (ne remplace pas
      # cache.nixos.org). Clé publique : README de sadjow/claude-code-nix.
      # Idem pour ros.cachix.org (nix-ros-overlay) : sans ça, tout ROS2 se
      # recompile depuis les sources sur chaque machine qui ouvre un projet
      # ROS (build de plusieurs dizaines de minutes).
      extra-substituters = [
        "https://claude-code.cachix.org"
        "https://ros.cachix.org"
      ];
      extra-trusted-public-keys = [
        "claude-code.cachix.org-1:YeXf2aNu7UTX8Vwrze0za1WEDS+4DuI2kVeWEE4fsRk="
        "ros.cachix.org-1:dSyZxI8geDCJrwgvCOHDoAfOm5sV1wCPjBkKL+38Rvo="
      ];
    };
    # Config 100 % flake : les channels (ancien mécanisme) ne servent plus.
    # Coupe leur gestion et leur entrée NIX_PATH ; les vieux profils de
    # channels (25.05, restes d'avant la migration flake) sont à retirer une
    # fois à la main : nix-channel --remove <nom> (user et root).
    channel.enable = false;
  };

  # GC automatique : ne supprime QUE les chemins orphelins du store, jamais
  # les générations (pas de --delete-older-than). La rétention des
  # générations est pilotée interactivement par genclean — un timer qui les
  # supprimait à 14 jours écrasait silencieusement le choix fait là-bas.
  nix.gc = {
    automatic = true;
    dates = "weekly";
  };

  # Déduplication du store par hardlinks (job périodique, complète le gc).
  nix.optimise.automatic = true;

  # Plafond du journal systemd. Sans ça, la limite par défaut est 10 % du
  # système de fichiers, soit ~19 Go ici : un plafond invisible, jamais
  # atteint en usage normal, mais qui laisse le journal grossir sans fin.
  # 500 Mo couvrent largement plusieurs semaines de logs.
  services.journald.extraConfig = "SystemMaxUse=500M";

  # Manuel NixOS local (nixos-help) : jamais utilisé, et sa génération coûte
  # à chaque rebuild. Les man pages classiques restent actives.
  documentation.nixos.enable = false;

  # Firmwares redistribuables : couvre tout le matériel réel (iwlwifi, BT
  # Intel, GPU via linux-firmware ; le son via sof-firmware, aussi ajouté
  # explicitement dans modules/system/audio). enableAllFirmware n'ajoutait
  # que de l'exotique hors sujet (b43/Broadcom, webcam Apple, dongle Xbox).
  hardware.enableRedistributableFirmware = true;

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Découverte des imprimantes réseau (mDNS / IPP Everywhere) + résolution des
  # noms en .local. Sans ça, CUPS ne voit que les imprimantes ajoutées à la main.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
  };

  # Profils d'alimentation (powerprofilesctl) : utilisés par lg-control et le
  # module batterie de waybar. Activé explicitement — il n'était fourni
  # qu'indirectement par le module GNOME (dépendance cachée sur un host sans
  # GNOME).
  services.power-profiles-daemon.enable = true;

  # Mises à jour de firmware matériel (BIOS, SSD, docks...) via LVFS.
  # Passif : rien ne se flashe sans un `fwupdmgr update` manuel.
  services.fwupd.enable = true;

  # Binaires dynamiques non-Nix (prebuilds npm type esbuild/sharp, installeurs
  # curl|sh, serveur VS Code Remote...) : ils cherchent leur loader en dur à
  # /lib64/ld-linux-x86-64.so.2, absent sur NixOS → « No such file or
  # directory » cryptique. nix-ld pose un shim à ce chemin ; passif tant
  # qu'aucun binaire étranger ne tourne.
  programs.nix-ld.enable = true;

  environment.systemPackages = with pkgs-stable; [
    # Portails xdg gérés par xdg.portal dans modules/system/sway (screencast).
    # Les outils GPU (nvtop, clinfo) sont dans modules/system/intel-graphics.
    lm_sensors
  ];

  environment.sessionVariables = {
    # Force les apps Electron/Chromium (Discord, Spotify, VSCode, ...) à utiliser
    # Wayland nativement. Sans ça elles tombent en mode X11 et meurent ("Missing
    # X server or $DISPLAY") quand le chemin XWayland est cassé (DISPLAY hérité
    # de GDM pointant sur un serveur X inexistant).
    NIXOS_OZONE_WL = "1";
    # Firefox en Wayland natif (il auto-détecte déjà, mais on le garantit).
    MOZ_ENABLE_WAYLAND = "1";
  };

  # system.stateVersion est une valeur PAR MACHINE (release de la première
  # installation) : elle vit dans hosts/<host>/configuration.nix, pas ici —
  # un futur host installé sur une release plus récente doit avoir la sienne.
}
