{ config, lib, ... }:

let
  cfg = config.userSettings.wifiPicker;
  term = config.userSettings.terminal.default;

  # Thème sombre pour nmtui via NEWT_COLORS.
  newtColors = "NEWT_COLORS="
    + "root=white,black:"
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

  termCmd =
    if term == "alacritty"
    then "${term} --title nmtui-wifi -e nmtui"
    else "${term} --title nmtui-wifi nmtui";

in {
  options.userSettings.wifiPicker = {
    enable = lib.mkEnableOption "sélecteur WiFi (nmtui dans terminal flottant)";
    pkgs = lib.mkOption {
      type = lib.types.attrs;
      default = config.userSettings.defaultPkgs;
      description = "Pkgs to use";
    };
  };

  config = lib.mkIf cfg.enable {
    # Launcher partagé entre le bind sway et le clic sur la swaybar (DRY).
    home.file.".config/sway/launchers/wifi" = {
      text = ''
        #!/bin/sh
        ${newtColors} exec ${termCmd}
      '';
      executable = true;
    };

    home.file.".config/sway/conf.d/wifi-picker.conf".text = ''
      bindsym $mod+w exec ~/.config/sway/launchers/wifi
      for_window [title="nmtui-wifi"] floating enable, resize set 1200 850, border pixel 2
    '';
  };
}
