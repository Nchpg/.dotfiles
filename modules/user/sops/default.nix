{
  config,
  lib,
  osConfig,
  ...
}:

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

  # Ce user a-t-il accès aux secrets ? Il faut qu'il puisse lire la clé age :
  # le keyOwner (à qui elle appartient) ou root (qui outrepasse les
  # permissions). Les autres (guest) n'y ont pas accès.
  hasSopsAccess = config.userSettings.user == keyOwner || config.userSettings.user == "root";
in
{
  options.userSettings.sops.available = lib.mkOption {
    type = lib.types.bool;
    readOnly = true;
    description = ''
      Vrai si ce user a accès aux secrets sops (keyOwner ou root). Les modules
      qui déclarent des secrets (calendar-tui, task-tui, gh, wakatime,
      git-email) peuvent asserter dessus pour échouer avec un message clair au
      lieu d'une erreur sops-nix cryptique quand ils sont activés pour un user
      sans clé. NB : ne vérifie QUE le droit d'accès (eval pur) — que la clé
      soit bien présente et déchiffre est vérifié par sops-nix à l'activation.
    '';
  };

  config = {
    userSettings.sops.available = hasSopsAccess;

    # Outils pour editer les secrets et enroler de nouvelles machines. Seulement
    # pour le detenteur de la cle : les autres users n'editent pas les secrets.
    # defaultPkgs (et pas l'instance globale `pkgs`) : même source que les
    # autres modules user.
    home.packages = lib.mkIf (config.userSettings.user == keyOwner) (
      with config.userSettings.defaultPkgs;
      [
        sops
        age
        ssh-to-age
      ]
    );

    # Seulement pour le keyOwner et root : les autres users (guest) ne peuvent
    # pas lire la cle, donc tout secret declare chez eux echouerait a
    # l'activation avec une erreur obscure — autant ne pas leur poser de config
    # sops du tout (l'erreur devient alors "no keyFile", explicite).
    sops = lib.mkIf hasSopsAccess {
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
  };
}
