{ config, lib, ... }:

let
  cfg = config.userSettings.bluetoothPicker;
  term = config.userSettings.terminal.default;

  termCmd = import ../../../lib/mk-terminal-cmd.nix {
    inherit lib term;
    title = "bluetui";
    exec = "bluetui";
  };
in
{
  options.userSettings.bluetoothPicker = {
    # Suit waybar : son bloc bluetooth a un on-click vers ce picker.
    enable = lib.mkEnableOption "sélecteur Bluetooth (bluetui dans terminal flottant)" // {
      default = config.userSettings.waybar.enable;
    };
    pkgs = import ../../../lib/mk-pkgs-option.nix { inherit lib config; };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (import ../../../lib/mk-floating-tui-launcher.nix {
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
