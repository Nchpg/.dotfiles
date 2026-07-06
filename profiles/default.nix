{ config, target, inputs, ... }:

{
  imports = [
    (./. + "/${target.profile}")
  ];

  config = {
    home-manager.users = builtins.listToAttrs
      (map (user: {
        inherit (user) name;
        value = {
          imports = [
            # stylix
            inputs.stylix.homeModules.stylix
            # sops-nix (secrets chiffres -> fichiers $HOME a l'activation)
            inputs.sops-nix.homeManagerModules.sops
            # spicetify (Spotify patché, cf. modules/user/spotify)
            inputs.spicetify-nix.homeManagerModules.default
            # build user
            (./. + "/${target.profile}/home/${user.name}")
            # user modules
            ../modules/user
          ];
          config = { 
            userSettings.user = user.name; 
          };
        };
      })
      (config.systemSettings.users ++ [{name = "root";}]));
    };
}