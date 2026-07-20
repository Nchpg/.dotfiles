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
