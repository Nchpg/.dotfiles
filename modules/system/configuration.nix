{ lib, pkgs-stable, target, ... }:

{
  home-manager.backupFileExtension = "hm-backup";
  nixpkgs.config.allowUnfree = true;

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # GPU
  hardware.graphics.enable = true;
  services.xserver.videoDrivers = [ "modesetting" ];

  # Active Flake
  nix = {
    package = pkgs-stable.nix;
    settings.experimental-features = [ "nix-command" "flakes" ];
  };

  # Define your hostname.
  networking.hostName = "${target.profile}-${target.host}"; 

  # Use all available firmware (needed for sound)
  hardware.enableAllFirmware = true;

  # Enable networking
  networking.networkmanager.enable = true;
    
  # Set your time zone.
  time.timeZone = "Europe/Paris";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "fr_FR.UTF-8";
    LC_IDENTIFICATION = "fr_FR.UTF-8";
    LC_MEASUREMENT = "fr_FR.UTF-8";
    LC_MONETARY = "fr_FR.UTF-8";
    LC_NAME = "fr_FR.UTF-8";
    LC_NUMERIC = "fr_FR.UTF-8";
    LC_PAPER = "fr_FR.UTF-8";
    LC_TELEPHONE = "fr_FR.UTF-8";
    LC_TIME = "fr_FR.UTF-8";
  };

  # Enable the GNOME GDM.
  services.xserver.displayManager.gdm.enable = true;

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Enable sound with pipewire.
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    wireplumber.enable = true;
    jack.enable = true;
  };

  # Enable Docker
  virtualisation.docker = {
    enable = true;
  };

  # Enable touchpad support (enabled default in most desktopManager).
  services.libinput.enable = true;

  # Configure keymap in X11
  services.xserver = {
    enable = true;

    xkb = {
      layout = "fr";
      variant = "azerty";
    };
  };

  # Configure console keymap
  console.keyMap = "fr";


  hardware.bluetooth.enable = true;

  # Enable thunar
  programs.thunar.enable = true;

  # Enable automatic garbage collection
  nix.gc = {
    automatic = true; # Run the garbage collector automatically
    dates = "weekly"; # How often to run it
    options = "--delete-older-than 14d"; # What to delete
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.05"; # Did you read the comment?
}