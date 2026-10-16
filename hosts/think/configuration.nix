{
  lib,
  inputs,
  target,
  ...
}:

{
  # Déclare les apps conteneurisées : exige proxy + nftables + pairs WireGuard.
  imports = lib.optional (target.profile == "server") "${inputs.secrets}/think.nix";

  systemSettings.storage.swap = {
    zram.enable = true;
    earlyoom.enable = true;
  };

  system.stateVersion = "26.05";

  home-manager.sharedModules = [ { home.stateVersion = lib.mkDefault "26.05"; } ];
}
