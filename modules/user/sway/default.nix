{ config, lib, pkgs-stable, pkgs-unstable, systemSettings, stylix, ... }:

let
  cfg = systemSettings.window-manager.sway;

  # Edit config template terminal
  templateContent = builtins.readFile ./sway-config/config.template;

  # Commande pour lancer le terminal directement dans tmux.
  # alacritty exige -e ; kitty et foot acceptent le programme directement.
  term = config.userSettings.terminal.default;
  # TMUX_TMPDIR aligné sur celui des shells (home-manager fixe $XDG_RUNTIME_DIR)
  # pour viser le même serveur tmux. sway exec passe par sh -c → $XDG_RUNTIME_DIR
  # est bien expansé, et il est toujours défini dans une session sway/wayland.
  tmuxCmd = "env TMUX_TMPDIR=$XDG_RUNTIME_DIR tmux new-session -A -s main";
  tmuxLaunch =
    if term == "alacritty"
    then "${term} -e ${tmuxCmd}"
    else "${term} ${tmuxCmd}";

  # Binding Ctrl+Return → terminal dans tmux, seulement si tmux est activé.
  tmuxBind =
    lib.optionalString config.userSettings.tmux.enable
      "bindsym Control+Return exec ${tmuxLaunch}";

  finalConfigContent = lib.replaceStrings
    ["@terminal@" "@tmuxBind@"]
    [config.userSettings.terminal.default tmuxBind]
    templateContent;
in {
  config = lib.mkIf cfg.enable {
    home.file.".config/sway/config" = {
      text = finalConfigContent;
    };

    home.file.".config/sway/brightness.sh" = {
      source = ./sway-config/brightness.sh;
      executable = true;
    };

    home.file.".config/sway/sway-bar.sh" = {
      source = ./sway-config/sway-bar.sh;
      executable = true;
    };

    home.file.".config/sway/wallpaper.png".source = ./sway-config/wallpaper.png;

    # Capture d'écran (flameshot + grim/slurp/wl-clipboard) : module dédié
    # modules/user/flameshot. Les binds Print/Shift+Print, le daemon et les
    # règles for_window restent dans sway-config/config.template.
    home.packages = with cfg.pkgs; [
      dmenu # mod + d menu

      # Sway bar dependencies
      acpi # Power battery
      alsa-utils # Sound
      brightnessctl # Brightness (remplace `light`, retiré en nixpkgs 26.05)
      playerctl # Audio player

      # Lock screen
      swaylock-effects
    ];

    stylix.targets.sway.enable = true;
  };
}
