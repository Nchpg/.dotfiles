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
    assertions = map (user: {
      assertion = builtins.pathExists (homeDir user);
      message = "profiles/${target.profile}/home/${user.name} est introuvable : crée ce dossier (config home-manager du user « ${user.name} »).";
    }) users;

    home-manager.users = builtins.listToAttrs (
      map (user: {
        inherit (user) name;
        value = {
          imports = [
            # stylix
            inputs.stylix.homeModules.stylix
            # sops-nix (secrets chiffres -> fichiers $HOME a l'activation)
            inputs.sops-nix.homeManagerModules.sops
            # spicetify (Spotify patché, cf. modules/user/spotify)
            inputs.spicetify-nix.homeManagerModules.default
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
