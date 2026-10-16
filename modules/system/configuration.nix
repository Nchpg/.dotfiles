{ pkgs-stable, ... }:

{
  home-manager.backupFileExtension = "hm-backup";

  nixpkgs.pkgs = pkgs-stable;

  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      # Une clé de confiance autorise ce cache à servir n'importe quel chemin du store.
      extra-substituters = [
        "https://claude-code.cachix.org"
      ];
      extra-trusted-public-keys = [
        "claude-code.cachix.org-1:YeXf2aNu7UTX8Vwrze0za1WEDS+4DuI2kVeWEE4fsRk="
      ];
    };
    channel.enable = false;

    # Par !include : access-tokens écrirait le jeton dans /etc/nix/nix.conf, lisible par tous.
    extraOptions = ''
      !include /var/lib/nix/access-tokens.conf
    '';
  };

  # 0600 root : un processus utilisateur ne doit pas pouvoir cloner le dépôt privé.
  # Le répertoire DOIT rester 0755, sinon nix abandonne tout nix.conf sans message.
  systemd.tmpfiles.rules = [
    "d /var/lib/nix 0755 root root -"
    "f /var/lib/nix/access-tokens.conf 0600 root root"
  ];

  nix.gc = {
    automatic = true;
    dates = "weekly";
  };

  nix.optimise.automatic = true;

  # EXPIRE(option:services.journald.settings): migrer extraConfig vers cette option
  services.journald.extraConfig = "SystemMaxUse=500M";

  documentation.nixos.enable = false;

  hardware.enableRedistributableFirmware = true;

  networking.firewall.enable = true;

  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs-stable; [
    stdenv.cc.cc.lib
    zlib
    openssl
    wayland
    libxkbcommon
    vulkan-loader
    libGL
    dbus
    alsa-lib
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
    NIXOS_OZONE_WL = "1";
    MOZ_ENABLE_WAYLAND = "1";
  };
}
