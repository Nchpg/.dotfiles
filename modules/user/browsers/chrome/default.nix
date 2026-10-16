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
        description = "Paquet du navigateur (google-chrome : codecs propriétaires + Widevine, utile pour Teams).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    programs.chromium = {
      enable = true;
      inherit (cfg) package;

      commandLineArgs = [
        "--ozone-platform-hint=auto"
        "--enable-features=WaylandWindowDecorations"
        "--restore-last-session"
      ];
    };

    # Nom de binaire, pas chemin store : le PATH doit résoudre le wrapper home-manager (flags Wayland).
    home.file.".config/sway/conf.d/chrome.conf" =
      lib.mkIf config.userSettings.windowManager.sway.enable
        {
          text = ''
            bindsym $mod+Shift+c exec ${baseNameOf (lib.getExe cfg.package)}
          '';
        };
  };
}
