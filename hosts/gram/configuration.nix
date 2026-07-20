{ ... }:

# Réglages matériel de gram (LG Gram 2024, Meteor Lake), importés par
# hosts/default.nix. hardware-configuration.nix est généré à part.
{
  systemSettings.intelGraphics.enable = true;
  systemSettings.displaylink.enable = true; # dock Dell D3100

  # Réduit le throttling en pilotant P-states/RAPL avant les limites CPU.
  services.thermald.enable = true;

  systemSettings.lgLaptop = {
    enable = true;
    batteryCareLimit = 80;
  };

  # Release de la première installation de CE host : ne suit PAS les
  # upgrades, valeur par machine comme hardware-configuration.nix.
  system.stateVersion = "25.05";
}
