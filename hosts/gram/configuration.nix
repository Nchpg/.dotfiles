{ ... }:

# Réglages propres au matériel de gram (LG Gram 2024, Meteor Lake).
# hardware-configuration.nix est généré ; ici, les choix manuels liés au host.
# (Importé automatiquement par hosts/default.nix quand ce fichier existe.)
{
  systemSettings.intelGraphics.enable = true;

  # Dock Dell D3100 (DisplayLink) : sorties vidéo du dock via USB.
  systemSettings.displaylink.enable = true;

  # Gestion thermique proactive Intel (daemon officiel) : réduit le throttling
  # en pilotant P-states/RAPL avant que le CPU n'atteigne ses limites.
  # Complémentaire de power-profiles-daemon (activé dans modules/system/
  # configuration.nix).
  services.thermald.enable = true;

  # Driver lg-laptop (fan mode sans root, limite de charge batterie).
  systemSettings.lgLaptop = {
    enable = true;
    batteryCareLimit = 80;
  };

  # Release NixOS de la première installation de CE host (défauts des données
  # stateful : emplacements de fichiers, versions de bases...). À laisser tel
  # quel — ne suit PAS les upgrades. Valeur par machine, comme
  # hardware-configuration.nix.
  system.stateVersion = "25.05";
}
