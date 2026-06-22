{ lib, pkgs-stable, pkgs-unstable, target, ... }:

{
  home-manager.backupFileExtension = "hm-backup";
  nixpkgs.config.allowUnfree = true;

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelPackages = pkgs-stable.linuxPackages_latest;

  # GPU
  services.xserver.videoDrivers = [ "modesetting" ];

  boot.kernelParams = [ "i915.force_probe=!7d55" "xe.force_probe=7d55" ];
  boot.kernelModules = [ "xe" ];

  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs-unstable; [
      intel-compute-runtime            # OpenCL driver (libigdrcl.so)
      intel-compute-runtime.drivers    # Level-Zero GPU driver (libze_intel_gpu.so) -> /run/opengl-driver/lib
      intel-media-driver
      vpl-gpu-rt
      level-zero
      clinfo
    ];
  };

  hardware.firmware = with pkgs-stable; [
    sof-firmware
  ];


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
  networking.useDHCP = false;

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
  services.displayManager.gdm.enable = true;

  # Trousseau de secrets (mots de passe Chrome, Wi-Fi, etc.). Le démon stocke la
  # clé qui chiffre les secrets ; le hook PAM sur gdm-password déverrouille le
  # trousseau « login » avec ton mot de passe de session à la connexion, sinon
  # Chrome réclame « Authentication required » au démarrage.
  services.gnome.gnome-keyring.enable = true;
  security.pam.services.gdm-password.enableGnomeKeyring = true;

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

    # Le périphérique par défaut suit la priorité (priority.session) au lieu d'être
    # épinglé. Les sorties Bluetooth ont une priorité plus haute que le haut-parleur
    # interne : à la connexion elles deviennent donc la sortie par défaut, et les
    # binds sway (wpctl ... @DEFAULT_AUDIO_SINK@) les contrôlent automatiquement.
    wireplumber.extraConfig."51-default-follow-priority" = {
      "wireplumber.settings" = {
        "node.restore-default-targets" = false;
      };
    };
  };

  # Enable Docker
  virtualisation = {
    docker = {
      enable = true;
      daemon.settings = {
        dns = [ "8.8.8.8" "1.1.1.1" ];
      };
    };
    libvirtd.enable = true;
  };

  environment.systemPackages = with pkgs-stable; [
    virt-manager
    udiskie
    # Portails xdg gérés par xdg.portal dans modules/system/sway (screencast).
    nvtopPackages.full
    lm_sensors
  ];

  environment.sessionVariables = {                                                                         
    LIBVA_DRIVER_NAME = "iHD";
    MOZ_DISABLE_RDD_SANDBOX = "1";
  };

  # Manage external disks
  services.udisks2.enable = true;
  boot.supportedFilesystems = [ "ntfs" ];

  systemd.user.services.udiskie = {
    description = "udiskie automounter";
    wantedBy = [ "default.target" ];
    serviceConfig.ExecStart = "${pkgs-stable.udiskie}/bin/udiskie --tray"; # --tray affiche l'icône en bas à droite
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


  hardware.bluetooth = {
    enable = true;
    # Experimental active le report du niveau de batterie des appareils BT (via D-Bus).
    settings.General.Experimental = true;
  };

  # Enable thunar
  programs.thunar.enable = true;

  # Enable automatic garbage collection
  nix.gc = {
    automatic = true; # Run the garbage collector automatically
    dates = "weekly"; # How often to run it
    options = "--delete-older-than 14d"; # What to delete
  };

  services.ollama = {
    enable = true;
    package = pkgs-unstable.ollama-vulkan;
    environmentVariables = {
      ZES_ENABLE_SYSMAN = "1";
      # Offload the model to the Arc iGPU via Vulkan. NOTE: the `xe` driver can
      # intermittently hang GPU compute on this Meteor Lake (TLB invalidation
      # fence timeouts) — if ollama freezes at "warming up", remove this line to
      # fall back to CPU, or switch the GPU from xe -> i915 for stability.
      OLLAMA_IGPU_ENABLE = "1";
    };
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


  fonts.packages = [
    pkgs-stable.nerd-fonts.fira-code
    pkgs-stable.twitter-color-emoji
    pkgs-stable.fira-sans
  ];

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.05"; # Did you read the comment?
}
