{ config, lib, ... }:

let
  cfg = config.userSettings.bluetoothPicker;
  term = config.userSettings.terminal.default;

  # bluetui (ratatui) utilise la palette du terminal : il hérite donc
  # automatiquement du thème Stylix via le terminal (kitty), comme nmtui
  # avec NEWT_COLORS pour le wifi-picker.
  termCmd = import ../../../lib/mk-terminal-cmd.nix {
    inherit lib term;
    title = "bluetui";
    exec = "bluetui";
  };
in
{
  options.userSettings.bluetoothPicker = {
    # Défaut : suit waybar (son bloc bluetooth a un on-click vers ce picker).
    # Surchargeable : mettre false pour une waybar sans bouton bluetooth.
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
