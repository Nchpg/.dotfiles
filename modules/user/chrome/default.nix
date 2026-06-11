{ config, lib, pkgs-stable, ... }:

let
  cfg = config.userSettings.chrome;
in {
  options = {
    userSettings.chrome = {
      enable = lib.mkEnableOption "Enable Google Chrome browser";
      pkgs = lib.mkOption {
        type = lib.types.attrs;
        default = config.userSettings.defaultPkgs;
        description = "Pkgs to use";
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = cfg.pkgs.google-chrome;
        description = ''
          Paquet du navigateur. google-chrome (codecs propriétaires +
          Widevine) est recommandé pour Teams. Remplaçable par
          cfg.pkgs.chromium / cfg.pkgs.ungoogled-chromium.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # google-chrome est unfree : allowUnfree est déjà activé dans le profil.
    programs.chromium = {
      enable = true;
      package = cfg.package;

      # Rendu natif Wayland sous Sway (sinon flou/XWayland et tearing).
      commandLineArgs = [
        "--ozone-platform-hint=auto"
        "--enable-features=WaylandWindowDecorations"
      ];
    };
  };
}
