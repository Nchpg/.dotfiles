{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.windowManager.sway.pickers.bluetooth;
  term = config.userSettings.terminal.default;

  termCmd = myLib.mkTerminalCmd {
    inherit lib term;
    title = "bluetui";
    exec = "bluetui";
  };
in
{
  options.userSettings.windowManager.sway.pickers.bluetooth = {
    # Suit waybar : son bloc bluetooth a un on-click vers ce picker.
    enable = lib.mkEnableOption "sélecteur Bluetooth (bluetui dans terminal flottant)" // {
      default = config.userSettings.windowManager.sway.waybar.enable;
    };
    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (myLib.mkFloatingTuiLauncher {
        name = "bluetooth";
        confName = "bluetooth-picker";
        scriptBody = "exec ${termCmd}";
        keybind = "$mod+b";
        title = "bluetui";
        width = 1200;
        height = 850;
      })
      {
        home.packages = [ cfg.pkgs.bluetui ];

        # Échap quitte bluetui (par défaut seuls q / ctrl+c quittent).
        xdg.configFile."bluetui/config.toml".text = ''
          esc_quit = true
        '';
      }
    ]
  );
}
