{ config, lib, pkgs-stable, pkgs-unstable, systemSettings, ... }:

let
  cfg = systemSettings.window-manager.sway;

  # Edit config template terminal
  templateContent = builtins.readFile ./sway-config/config.template;
  finalConfigContent = lib.replaceStrings ["@terminal@"] [config.userSettings.terminal.default] templateContent;
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

    
    home.packages = with cfg.pkgs; [
      dmenu # mod + d menu

      # Sway bar dependencies
      acpi # Power battery 
      alsa-utils # Sound
      light # Brightness
      playerctl # Audio player

      # Screenshot
      grim
      slurp
      wl-clipboard

      # Lock screen
      swaylock-effects
    ];
  };
}
