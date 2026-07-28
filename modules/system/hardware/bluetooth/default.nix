{ config, lib, ... }:

# Suit systemSettings.desktop.enable : une pile BlueZ qui écoute sur un
# contrôleur que personne n'appaire est une surface d'attaque gratuite.
lib.mkIf config.systemSettings.desktop.enable {
  hardware.bluetooth = {
    enable = true;
    # BlueZ n'expose pas de flag plus fin : active TOUTES ses features
    # expérimentales (dont le report batterie via D-Bus, visé ici).
    settings.General.Experimental = true;
  };
}
