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

  orphanHmUsers = lib.subtractLists (map (u: u.name) users) (lib.attrNames config.home-manager.users);
in
{
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
    # listToAttrs ne garde que la première entrée d'un doublon, sans message.
    ++ [
      {
        assertion = lib.length (lib.unique (map (u: u.name) users)) == lib.length users;
        message = "systemSettings.users contient des noms dupliqués (rappel : \"root\" est déjà ajouté automatiquement par profiles/default.nix, ne le déclare pas).";
      }

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
            # spicetify-nix n'expose que homeManagerModules.
            inputs.spicetify-nix.homeManagerModules.default
            inputs.nix-index-database.homeModules.nix-index
            ../modules/user
          ]
          ++ lib.optional (builtins.pathExists (homeDir user)) (homeDir user);
          config = {
            userSettings.user = user.name;
          };
        };
      }) users
    );
  };
}
