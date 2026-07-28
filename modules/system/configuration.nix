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
  };

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
