{
  config,
  lib,
  target,
  inputs,
  ...
}:

let
  users = config.systemSettings.users ++ [ { name = "root"; } ];
  homeDir = user: ./. + "/${target.profile}/home/${user.name}";
  profileDir = ./. + "/${target.profile}";

  # Users configurés côté home-manager mais jamais déclarés dans
  # systemSettings.users. Pas de récursion : `home-manager.users` est défini
  # plus bas SANS lire cette liste, on ne force ici que les NOMS d'attributs.
  orphanHmUsers = lib.subtractLists (map (u: u.name) users) (lib.attrNames config.home-manager.users);
in
{
  # Même filet que hosts/default.nix, par symétrie.
  imports = lib.optional (builtins.pathExists profileDir) profileDir;

  config = {
    assertions = [
      {
        assertion = builtins.pathExists profileDir;
        message = "profiles/${target.profile} est introuvable.";
      }
    ]
    ++ map (user: {
      assertion = builtins.pathExists (homeDir user);
      message = "profiles/${target.profile}/home/${user.name} est introuvable : crée ce dossier (config home-manager du user « ${user.name} »).";
    }) users
    # listToAttrs (ci-dessous et modules/system/users) ne garde que la
    # PREMIÈRE entrée d'un doublon : un second user homonyme perdrait ses
    # groupes/isAdmin sans le moindre message.
    ++ [
      {
        assertion = lib.length (lib.unique (map (u: u.name) users)) == lib.length users;
        message = "systemSettings.users contient des noms dupliqués (rappel : \"root\" est déjà ajouté automatiquement par profiles/default.nix, ne le déclare pas).";
      }

      # Réciproque de l'assertion « dossier home introuvable » ci-dessus : celle-ci
      # part des users DÉCLARÉS et vérifie leur dossier, celle-là part des users
      # CONFIGURÉS et vérifie qu'ils sont déclarés. Cas visé : un
      # `home-manager.users.<nom>` posé ailleurs (typiquement un
      # hosts/<host>/configuration.nix qui surcharge un home.stateVersion) avec
      # un nom mal orthographié.
      #
      # Ce n'est PAS un trou de sécurité : le module NixOS de home-manager fait
      # `users.users = mapAttrs … home-manager.users`, donc un nom fantôme
      # déclenche déjà les assertions amont. Mais elles parlent de
      # `users.users.<nom>` — « Exactly one of isSystemUser and isNormalUser
      # must be set », « group is unset » — et désignent une option que
      # personne n'a écrite : rien ne renvoie vers la faute de frappe, dans un
      # fichier de host, sur une option home-manager. Cette assertion-ci nomme
      # le coupable et l'endroit où chercher. Gain de diagnostic, pas de
      # couverture. Vérifié dans les deux sens.
      {
        assertion = orphanHmUsers == [ ];
        message = "home-manager.users configure des users absents de systemSettings.users (faute de frappe dans un hosts/<host>/configuration.nix ?) : ${lib.concatStringsSep ", " orphanHmUsers}.";
      }
    ];

    home-manager.users = builtins.listToAttrs (
      map (user: {
        inherit (user) name;
        value = {
          imports = [
            inputs.stylix.homeModules.stylix
            inputs.sops-nix.homeModules.sops
            # spicetify-nix n'expose QUE homeManagerModules, pas homeModules.
            inputs.spicetify-nix.homeManagerModules.default
            inputs.nix-index-database.homeModules.nix-index
            ../modules/user
          ]
          # Gardé par pathExists : l'assertion ci-dessus produit le message
          # d'erreur, pas l'import.
          ++ lib.optional (builtins.pathExists (homeDir user)) (homeDir user);
          config = {
            userSettings.user = user.name;
          };
        };
      }) users
    );
  };
}
