{ config, lib, ... }:

let
  cfg = config.userSettings.wifiPicker;
  term = config.userSettings.terminal.default;

  # Thème sombre pour nmtui via NEWT_COLORS.
  newtColors =
    "NEWT_COLORS="
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

  # kitty intercepte la touche AVANT de l'envoyer à l'app : on mappe q vers la
  # fermeture de la fenêtre flottante pour unifier la sortie de tous les TUIs
  # (nmtui ne quitte nativement qu'avec Esc, jamais avec q). Conséquence : q est
  # capturé par kitty et n'atteint plus nmtui — sans impact en usage courant,
  # mais on ne peut plus taper un « q » littéral (ex. mot de passe wifi).
  # confirm_os_window_close=0 évite le prompt de confirmation à la fermeture.
  kittyQuit = ''-o "map q close_window" -o confirm_os_window_close=0'';
  termCmd =
    if term == "alacritty" then
      "${term} --title nmtui-wifi -e nmtui"
    else if term == "kitty" then
      "${term} ${kittyQuit} --title nmtui-wifi nmtui"
    else
      "${term} --title nmtui-wifi nmtui";

in
{
  options.userSettings.wifiPicker = {
    # Défaut : suit waybar (son bloc réseau a un on-click vers ce picker).
    # Surchargeable : mettre false pour une waybar sans bouton wifi.
    enable = lib.mkEnableOption "sélecteur WiFi (nmtui dans terminal flottant)" // {
      default = config.userSettings.waybar.enable;
    };
    pkgs = lib.mkOption {
      type = lib.types.pkgs;
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
