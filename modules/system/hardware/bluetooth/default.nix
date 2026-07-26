{ ... }:

{
  hardware.bluetooth = {
    enable = true;
    # BlueZ n'expose pas de flag plus fin : active TOUTES ses features
    # expérimentales (dont le report batterie via D-Bus, visé ici).
    settings.General.Experimental = true;
  };
}
