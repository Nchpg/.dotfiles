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
in
{
  imports = [
    (./. + "/${target.profile}")
  ];

  config = {
    # Chaque user déclaré doit avoir son dossier profiles/<profil>/home/<user>.
    # Sans ce garde, ajouter un user sans créer le dossier faisait échouer
    # l'éval avec un « path does not exist » cryptique ; ici on échoue avec un
    # message clair (l'import est conditionné au pathExists ci-dessous).
    assertions =
      map (user: {
        assertion = builtins.pathExists (homeDir user);
        message = "profiles/${target.profile}/home/${user.name} est introuvable : crée ce dossier (config home-manager du user « ${user.name} »).";
      }) users
      # "root" est toujours ajouté ci-dessus : un profil qui le déclarerait aussi
      # dans systemSettings.users produirait un doublon silencieusement résolu
      # par listToAttrs (seule la première entrée serait gardée). On préfère
      # échouer avec un message clair plutôt que d'ignorer silencieusement la
      # déclaration explicite du profil.
      ++ [
        {
          assertion = !(lib.any (u: u.name == "root") config.systemSettings.users);
          message = "systemSettings.users ne doit pas déclarer \"root\" explicitement : il est déjà ajouté automatiquement par profiles/default.nix.";
        }
      ];

    home-manager.users = builtins.listToAttrs (
      map (user: {
        inherit (user) name;
        value = {
          imports = [
            # stylix
            inputs.stylix.homeModules.stylix
            # sops-nix (secrets chiffres -> fichiers $HOME a l'activation)
            inputs.sops-nix.homeModules.sops
            # spicetify (Spotify patché, cf. modules/user/spotify).
            # spicetify-nix n'expose QUE homeManagerModules (pas d'alias
            # homeModules, contrairement à sops-nix).
            inputs.spicetify-nix.homeManagerModules.default
            # nix-index avec base pré-construite (cf. modules/user/nix-index)
            inputs.nix-index-database.homeModules.nix-index
            # user modules
            ../modules/user
          ]
          # build user (gardé par pathExists : l'assertion ci-dessus produit le
          # message d'erreur, pas l'import)
          ++ lib.optional (builtins.pathExists (homeDir user)) (homeDir user);
          config = {
            userSettings.user = user.name;
          };
        };
      }) users
    );
  };
}
