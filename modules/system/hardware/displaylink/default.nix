{ config, lib, ... }:

let
  cfg = config.systemSettings.hardware.displaylink;
in
{
  options = {
    systemSettings.hardware.displaylink = {
      enable = lib.mkEnableOption "driver DisplayLink + evdi pour dock USB (Dell D3100)";
    };
  };

  config = lib.mkIf cfg.enable {
    # Fusionné avec "modesetting" de intel-graphics (la liste ne déduplique pas).
    services.xserver.videoDrivers = [ "displaylink" ];

    # evdi laisse un second curseur figé sous wlroots.
    environment.sessionVariables.WLR_NO_HARDWARE_CURSORS = "1";

    # Voulu seulement par la règle udev du dock ; Restart=always le gardait actif débranché.
    systemd.services.dlm.unitConfig.StopWhenUnneeded = true;
  };
}
