{
  config,
  lib,
  osConfig,
  myLib,
  ...
}:

let
  cfg = config.userSettings.windowManager.sway.pickers.wifi;

  # Thème sombre pour nmtui via NEWT_COLORS.
  newtColors =
    "root=white,black:"
    + "border=blue,black:"
    + "title=blue,black:"
    + "roottext=white,black:"
    + "window=white,black:"
    + "textbox=white,black:"
    + "listbox=white,black:"
    + "actlistbox=black,blue:"
    + "actsellistbox=black,blue:"
    + "entry=blue,black:"
    + "label=white,black:"
    + "checkbox=white,black:"
    + "actcheckbox=black,blue:"
    + "button=black,blue:"
    + "actbutton=white,black:"
    + "compactbutton=white,black";

  # nmtui ne quitte nativement qu'avec Esc : q mappé côté kitty pour unifier
  # la sortie des TUIs. Effet de bord : plus de "q" littéral tapable (mdp wifi).
  kittyQuit = ''-o "map q close_window" -o confirm_os_window_close=0'';
in
{
  options.userSettings.windowManager.sway.pickers.wifi = {
    # Suit waybar : son bloc réseau a un on-click vers ce picker.
    enable = lib.mkEnableOption "sélecteur WiFi (nmtui dans terminal flottant)" // {
      default = config.userSettings.windowManager.sway.waybar.enable;
    };
    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (myLib.mkFloatingTuiLauncher {
        name = "wifi";
        confName = "wifi-picker";
        inherit config;
        exec = "${cfg.pkgs.networkmanager}/bin/nmtui";
        env.NEWT_COLORS = newtColors;
        kittyExtraOpts = kittyQuit;
        keybind = "$mod+w";
        title = "nmtui-wifi";
        width = 1200;
        height = 850;
      })
      {
        assertions = [
          {
            assertion = osConfig.networking.networkmanager.enable;
            message = "userSettings.windowManager.sway.pickers.wifi a besoin de NetworkManager (nmtui), mais networking.networkmanager.enable est faux sur ce host.";
          }
        ];
      }
    ]
  );
}
