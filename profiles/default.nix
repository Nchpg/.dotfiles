{ config, target, inputs, ... }:

{
  imports = [
    (./. + "/${target.profile}")
  ];

  config = {
    home-manager.users = builtins.listToAttrs
      (map (user: {
        name = user.name;
        value = {
          imports = [ 
            # stylix
            inputs.stylix.homeModules.stylix
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