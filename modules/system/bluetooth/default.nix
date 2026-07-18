{ ... }:

{
  hardware.bluetooth = {
    enable = true;
    # BlueZ n'expose pas de flag plus fin : Experimental active TOUTES ses
    # fonctionnalités expérimentales (pas seulement celle visée ici), dont le
    # report du niveau de batterie des appareils BT (via D-Bus).
    settings.General.Experimental = true;
  };
}
