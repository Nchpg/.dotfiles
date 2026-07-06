{ config, lib, ... }:

let
  cfg = config.userSettings.bluetoothPicker;
  term = config.userSettings.terminal.default;

  # bluetui (ratatui) utilise la palette du terminal : il hérite donc
  # automatiquement du thème Stylix via le terminal (kitty), comme nmtui
  # avec NEWT_COLORS pour le wifi-picker.
  termCmd =
    if term == "alacritty"
    then "${term} --title bluetui -e bluetui"
    else "${term} --title bluetui bluetui";
in {
  options.userSettings.bluetoothPicker = {
    enable = lib.mkEnableOption "sélecteur Bluetooth (bluetui dans terminal flottant)";
    pkgs = lib.mkOption {
      type = lib.types.pkgs;
      default = config.userSettings.defaultPkgs;
      description = "Pkgs to use";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.pkgs.bluetui ];

    # Échap quitte bluetui (par défaut seuls q / ctrl+c quittent).
    xdg.configFile."bluetui/config.toml".text = ''
      esc_quit = true
    '';

    # Launcher partagé entre le bind sway et le clic sur la swaybar (DRY).
    home.file.".config/sway/launchers/bluetooth" = {
      text = ''
        #!/bin/sh
        exec ${termCmd}
      '';
      executable = true;
    };

    home.file.".config/sway/conf.d/bluetooth-picker.conf".text = ''
      bindsym $mod+b exec ~/.config/sway/launchers/bluetooth
      for_window [title="bluetui"] floating enable, resize set 1200 850, border pixel 2
    '';
  };
}
