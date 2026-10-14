{
  config,
  lib,
  osConfig,
  ...
}:

# Thunar « éphémère » du clic sur la case disque de waybar : flottant, Échap
# pour fermer, fermé à l'ouverture d'un fichier (cf. daemon.sh). Le clic
# lance `package` (launcher.sh), le démon tourne en service user.
let
  waybar = config.userSettings.windowManager.sway.waybar;
  cfg = waybar.thunarFloat;
  inherit (waybar) pkgs;

  # swaymsg du sway système (patché), pas un second sway tiré de pkgs.
  swayPkg = osConfig.programs.sway.package;

  launcher = pkgs.writeShellApplication {
    name = "thunar-float";
    runtimeInputs = [
      pkgs.coreutils
      swayPkg # swaymsg
      pkgs.thunar
    ];
    text = builtins.readFile ./launcher.sh;
  };
  daemon = pkgs.writeShellApplication {
    name = "thunar-float-daemon";
    runtimeInputs = [
      pkgs.coreutils
      swayPkg # swaymsg
      pkgs.jq
    ];
    text = builtins.readFile ./daemon.sh;
  };
in
{
  options.userSettings.windowManager.sway.waybar.thunarFloat = {
    # Suit waybar : seul le clic sur sa case disque ouvre ce Thunar-là.
    enable = lib.mkEnableOption "Thunar éphémère du clic sur la case disque de waybar" // {
      default = waybar.enable;
    };
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = launcher;
      description = "Lanceur du Thunar éphémère (on-click de la case disque).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.thunar-float = {
      Unit = {
        Description = "Thunar éphémère du clic waybar (flottant, Échap, fermé à l'ouverture)";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Install.WantedBy = [ "graphical-session.target" ];
      Service = {
        ExecStart = lib.getExe daemon;
        Restart = "on-failure";
      };
    };
  };
}
