{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.browsers.chrome;
in
{
  options = {
    userSettings.browsers.chrome = {
      enable = lib.mkEnableOption "Enable Google Chrome browser";
      pkgs = myLib.mkPkgsOption { inherit lib config; };
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
        # Rouvre fenêtres et onglets de la dernière fois, comme
        # browser.startup.page = 3 côté Firefox (cf. sway-session restore).
        "--restore-last-session"
      ];
    };
  };
}
