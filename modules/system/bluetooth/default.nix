{ ... }:

{
  hardware.bluetooth = {
    enable = true;
    # Experimental active le report du niveau de batterie des appareils BT (via D-Bus).
    settings.General.Experimental = true;
  };
}
