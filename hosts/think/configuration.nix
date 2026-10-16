{ lib, ... }:

{
  systemSettings.storage.swap = {
    zram.enable = true;
    earlyoom.enable = true;
  };

  system.stateVersion = "26.05";

  home-manager.sharedModules = [ { home.stateVersion = lib.mkDefault "26.05"; } ];
}
