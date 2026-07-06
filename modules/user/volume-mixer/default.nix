{ config, lib, ... }:

let
  cfg = config.userSettings.volumeMixer;
  term = config.userSettings.terminal.default;

  # ncpamixer (ncurses) utilise la palette du terminal : il hérite donc
  # automatiquement du thème Stylix via le terminal (kitty).
  # Padding interne plus large que le terminal courant pour ne pas coller aux bords.
  padOpt = lib.optionalString (term == "kitty") "-o window_padding_width=20 ";
  termCmd =
    if term == "alacritty"
    then "${term} --title ncpamixer -e ncpamixer"
    else "${term} ${padOpt}--title ncpamixer ncpamixer";
in {
  options.userSettings.volumeMixer = {
    enable = lib.mkEnableOption "mixeur audio (ncpamixer dans terminal flottant)";
    pkgs = lib.mkOption {
      type = lib.types.pkgs;
      default = config.userSettings.defaultPkgs;
      description = "Pkgs to use";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.pkgs.ncpamixer ];

    # Launcher partagé entre le bind sway et le clic sur la swaybar (DRY).
    home.file.".config/sway/launchers/volume-mixer" = {
      text = ''
        #!/bin/sh
        exec ${termCmd}
      '';
      executable = true;
    };

    home.file.".config/sway/conf.d/volume-mixer.conf".text = ''
      bindsym $mod+p exec ~/.config/sway/launchers/volume-mixer
      for_window [title="ncpamixer"] floating enable, resize set 1200 850, border pixel 2
    '';
  };
}
