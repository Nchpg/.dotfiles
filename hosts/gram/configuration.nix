{ lib, ... }:

# Réglages matériel de gram (LG Gram 2024, Meteor Lake), importés par
# hosts/default.nix. hardware-configuration.nix est généré à part.
{
  systemSettings.hardware = {
    intelGraphics.enable = true;
    displaylink.enable = true; # dock Dell D3100

    lgLaptop = {
      enable = true;
      batteryCareLimit = 80;
    };
  };

  # Dimensionné sur la RAM de CE host, pas sur le profil : pas de partition
  # de swap sur gram, la pression mémoire est absorbée par zram et earlyoom
  # tue avant que le système ne parte en thrashing.
  systemSettings.storage.swap = {
    zram.enable = true;
    earlyoom.enable = true;
  };

  # Modèles locaux : dépend du GPU et de la RAM de la machine, pas de la
  # persona — un host plus léger sous le même profil ne doit pas l'hériter.
  systemSettings.ollama.enable = true;

  # Release de la première installation de CE host : ne suit PAS les
  # upgrades, valeur par machine comme hardware-configuration.nix.
  system.stateVersion = "25.05";

  home-manager.sharedModules = [ { home.stateVersion = lib.mkDefault "25.05"; } ];
}
