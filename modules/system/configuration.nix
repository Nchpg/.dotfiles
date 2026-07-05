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
    package = pkgs-stable.nix;
    settings.experimental-features = [ "nix-command" "flakes" ];
  };

  # Enable automatic garbage collection
  nix.gc = {
    automatic = true; # Run the garbage collector automatically
    dates = "weekly"; # How often to run it
    options = "--delete-older-than 14d"; # What to delete
  };

  # Use all available firmware (needed for sound)
  hardware.enableAllFirmware = true;

  # Enable CUPS to print documents.
  services.printing.enable = true;

  environment.systemPackages = with pkgs-stable; [
    # Portails xdg gérés par xdg.portal dans modules/system/sway (screencast).
    nvtopPackages.full
    lm_sensors
    clinfo # diagnostic OpenCL (dans extraPackages il n'était pas dans le PATH)
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

  # services.elasticsearch = {
  #   enable = true;
  #   package = pkgs-stable.elasticsearch; # Compatible with 8.0.x for the TP

  #   listenAddress = "127.0.0.1";


  #   # Disable security as per the subject
  #   extraConf = ''
  #     xpack.security.enabled: false
  #   '';

  #   # Adjust JVM heap if needed (e.g., for low RAM)
  #   extraJavaOptions = [ "-Xms1g" "-Xmx1g" ];
  # };


  # services.redis.servers.default.enable = true;

  # services.neo4j= {
  #    enable = true;
  #    bolt = {
  #      tlsLevel = "DISABLED";
  #    };
  #    https = {
  #      enable = false;
  #    };
  #  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.05"; # Did you read the comment?
}
