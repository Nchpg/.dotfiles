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
    settings.experimental-features = [
      "nix-command"
      "flakes"
    ];
    # Config 100 % flake : les channels (ancien mécanisme) ne servent plus.
    # Coupe leur gestion et leur entrée NIX_PATH ; les vieux profils de
    # channels (25.05, restes d'avant la migration flake) sont à retirer une
    # fois à la main : nix-channel --remove <nom> (user et root).
    channel.enable = false;
  };

  # Enable automatic garbage collection
  nix.gc = {
    automatic = true; # Run the garbage collector automatically
    dates = "weekly"; # How often to run it
    options = "--delete-older-than 14d"; # What to delete
  };

  # Déduplication du store par hardlinks (job périodique, complète le gc).
  nix.optimise.automatic = true;

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

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.05"; # Did you read the comment?
}
