{
  config,
  lib,
  osConfig,
  inputs,
  ...
}:

# Config globale sops-nix ; secrets/templates individuels déclarés dans les
# modules qui les consomment (tui/calendar, tui/task).
# Clé de déchiffrement : ~/.config/sops/age/keys.txt, dérivée une fois de la
# clé SSH via `ssh-to-age -private-key -i ~/.ssh/id_ed25519 -o ...`.
# Éditer les secrets : `secrets user`. Cf. docs/secrets.md.
let
  keyOwner = osConfig.systemSettings.sops.keyOwner;

  # Peut lire la clé age : le keyOwner ou root (outrepasse les permissions).
  hasSopsAccess = config.userSettings.user == keyOwner || config.userSettings.user == "root";
in
{
  options.userSettings.sops.available = lib.mkOption {
    type = lib.types.bool;
    readOnly = true;
    description = ''
      Vrai si ce user a accès aux secrets sops (keyOwner ou root). Les modules
      qui déclarent des secrets (tui/calendar, tui/task, git/gh, editors/wakatime,
      git-email) peuvent asserter dessus pour échouer avec un message clair au
      lieu d'une erreur sops-nix cryptique quand ils sont activés pour un user
      sans clé. NB : ne vérifie QUE le droit d'accès (eval pur) — que la clé
      soit bien présente et déchiffre est vérifié par sops-nix à l'activation.
    '';
  };

  config = {
    userSettings.sops.available = hasSopsAccess;

    # Seulement pour le détenteur de la clé.
    home.packages = lib.mkIf (config.userSettings.user == keyOwner) (
      with config.userSettings.defaultPkgs;
      [
        sops
        age
        ssh-to-age
      ]
    );

    # Autres users (guest) : pas de config sops du tout, sinon erreur obscure
    # à l'activation plutôt qu'un "no keyFile" explicite.
    sops = lib.mkIf hasSopsAccess {
      # Dépôt PRIVÉ, séparé de celui-ci qui est public (cf. flake.nix). Le
      # pendant système lit `system.yaml` du même dépôt, chiffré pour d'autres
      # destinataires.
      defaultSopsFile = "${inputs.secrets}/secrets.yaml";
      defaultSopsFormat = "yaml";

      age = {
        # root réutilise la clé du keyOwner : il peut déjà tout déchiffrer
        # sur la machine, aucune perte de sécurité, pas de clé à part.
        keyFile = "/home/${keyOwner}/.config/sops/age/keys.txt";
        generateKey = false;
      };
    };
  };
}
