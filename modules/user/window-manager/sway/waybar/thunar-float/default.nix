{
  config,
  lib,
  osConfig,
  ...
}:

let
  waybar = config.userSettings.windowManager.sway.waybar;
  cfg = waybar.thunarFloat;
  inherit (waybar) pkgs;

  swayPkg = osConfig.programs.sway.package;

  launcher = pkgs.writeShellApplication {
    name = "thunar-float";
    runtimeInputs = [
      pkgs.coreutils
      swayPkg
      pkgs.thunar
    ];
    text = builtins.readFile ./launcher.sh;
  };
  daemon = pkgs.writeShellApplication {
    name = "thunar-float-daemon";
    runtimeInputs = [
      pkgs.coreutils
      swayPkg
      pkgs.jq
    ];
    text = builtins.readFile ./daemon.sh;
  };
in
{
  options.userSettings.windowManager.sway.waybar.thunarFloat = {
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
