{ config, lib, ... }:

let
  cfg = config.userSettings.windowManager.sway.waybar;
  inherit (cfg) scriptDir;
in
{
  options.userSettings.windowManager.sway.waybar.nightlight.fallbackCoords = {
    lat = lib.mkOption {
      type = lib.types.str;
      default = "47.47";
      description = "Latitude du night light si la ville météo n'a jamais pu être géocodée.";
    };
    lon = lib.mkOption {
      type = lib.types.str;
      default = "-0.55";
      description = "Longitude du night light si la ville météo n'a jamais pu être géocodée (défaut : Angers, première ville de weatherCities).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.wlsunset = {
      Unit = {
        Description = "wlsunset – température de couleur jour/nuit";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Install.WantedBy = [ "graphical-session.target" ];
      Service = {
        # Échec = "skipped" (pas failed) : pas de relance au login si coupé
        ExecCondition = "${scriptDir}/nightlight.sh allowed";
        ExecStart = "${scriptDir}/wlsunset-geo.sh";
        Restart = "on-failure";
      };
    };
  };
}
