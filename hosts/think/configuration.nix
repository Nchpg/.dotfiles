{ lib, ... }:

# Réglages matériel de gram (LG Gram 2024, Meteor Lake), importés par
# hosts/default.nix. hardware-configuration.nix est généré à part.
{
  # Dimensionné sur la RAM de CE host, pas sur le profil : pas de partition
  # de swap sur gram, la pression mémoire est absorbée par zram et earlyoom
  # tue avant que le système ne parte en thrashing.
  systemSettings.storage.swap = {
    zram.enable = true;
    earlyoom.enable = true;
  };

  # Release de la première installation de CE host : ne suit PAS les
  # upgrades, valeur par machine comme hardware-configuration.nix.
  system.stateVersion = "26.05";

  home-manager.sharedModules = [ { home.stateVersion = lib.mkDefault "26.05"; } ];
}
