{
  lib,
  inputs,
  target,
  ...
}:

# Réglages propres à think, importés par hosts/default.nix.
# hardware-configuration.nix est généré à part.
{
  # Configuration propre à cette machine qui n'a pas à être publiée. Elle vit
  # dans le dépôt de secrets, déjà entrée du flake et déjà épinglée par
  # flake.lock : ce qui est déployé ne change donc qu'après un
  # `nix flake update secrets`, qui se voit dans un diff ici — le même
  # raisonnement que pour les valeurs chiffrées.
  #
  # L'entrée est en `flake = false`, donc `inputs.secrets` est un CHEMIN DU
  # STORE. L'import reste par conséquent pur, et rebuild.sh n'a pas besoin de
  # `--impure`, ce qu'il refuse explicitement.
  #
  # Profil server UNIQUEMENT : ce fichier déclare les apps conteneurisées
  # (systemSettings.apps), qui exigent proxy + nftables et dérivent leurs
  # adresses des pairs WireGuard, absents du profil personal -> personal-think
  # ne s'évaluait plus.
  imports = lib.optional (target.profile == "server") "${inputs.secrets}/think.nix";

  # Dimensionné sur la RAM de CE host, pas sur le profil : pas de partition
  # de swap ici, la pression mémoire est absorbée par zram et earlyoom
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
