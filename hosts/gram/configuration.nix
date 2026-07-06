{ ... }:

# Réglages propres au matériel de gram (LG Gram 2024, Meteor Lake).
# hardware-configuration.nix est généré ; ici, les choix manuels liés au host.
# (Importé automatiquement par hosts/default.nix quand ce fichier existe.)
{
  systemSettings.intelGraphics.enable = true;

  # Driver lg-laptop (fan mode sans root, limite de charge batterie).
  systemSettings.lgLaptop = {
    enable = true;
    batteryCareLimit = 80;
  };
}
