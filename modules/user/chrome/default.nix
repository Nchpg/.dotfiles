{ config, lib, ... }:

let
  cfg = config.userSettings.chrome;
in
{
  options = {
    userSettings.chrome = {
      enable = lib.mkEnableOption "Enable Google Chrome browser";
      pkgs = import ../../../lib/mk-pkgs-option.nix { inherit lib config; };
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
    programs.chromium = {
      enable = true;
      inherit (cfg) package;

      # Rendu natif Wayland (sinon flou/XWayland et tearing).
      commandLineArgs = [
        "--ozone-platform-hint=auto"
        "--enable-features=WaylandWindowDecorations"
      ];
    };
  };
}
