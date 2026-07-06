{ config, lib, pkgs, osConfig, ... }:

# Configuration globale sops-nix cote home-manager. Les secrets individuels
# (et templates) sont declares dans les modules qui les consomment
# (calendar-tui, task-tui), pour rester cohesifs et ne se deployer que quand
# le module est active.
#
# Le detenteur de la cle est declare par le profil (systemSettings.sops.keyOwner,
# cf. modules/system/sops). Cle de dechiffrement : ~/.config/sops/age/keys.txt
# chez ce user, derivee une fois de sa cle SSH ed25519 via :
#   ssh-to-age -private-key -i ~/.ssh/id_ed25519 -o ~/.config/sops/age/keys.txt
#
# Editer les secrets :  sops secrets/secrets.yaml   (depuis la racine du repo)
let
  keyOwner = osConfig.systemSettings.sops.keyOwner;
in
{
  # Outils pour editer les secrets et enroler de nouvelles machines. Seulement
  # pour le detenteur de la cle : les autres users n'editent pas les secrets.
  home.packages = lib.mkIf (config.userSettings.user == keyOwner)
    (with pkgs; [ sops age ssh-to-age ]);

  sops = {
    defaultSopsFile = ../../../secrets/secrets.yaml;
    defaultSopsFormat = "yaml";

    age = {
      # Cle age unique = celle du keyOwner. root la reutilise : il peut lire ce
      # fichier (root outrepasse les permissions) et de toute facon root peut
      # deja tout dechiffrer sur la machine -> aucune perte de securite, et pas
      # de cle separee a maintenir pour root.
      keyFile = "/home/${keyOwner}/.config/sops/age/keys.txt";
      # On utilise directement keys.txt (derivee de la cle SSH), pas de
      # generation auto ni de derivation a l'activation.
      generateKey = false;
    };
  };
}
