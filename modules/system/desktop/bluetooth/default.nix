{ config, lib, ... }:

lib.mkIf config.systemSettings.desktop.enable {
  hardware.bluetooth = {
    enable = true;
    # Seul flag BlueZ pour le report batterie : active toutes les features expérimentales.
    settings.General.Experimental = true;
  };
}
