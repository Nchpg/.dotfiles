{ config, lib, pkgs-stable, ... }:

{
  options = {
    systemSettings = {
      users = lib.mkOption {
        description = "List of desktop users to create on the system";
        type = lib.types.listOf (lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Username";
            };
            isAdmin = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "If true, the user will be in the wheel group (sudo access)";
            };
            allowDocker = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "If true, the user will have access to docker";
            };
          };
        });
      };
    };
  };

  config = {
    # Mots de passe NON gérés en déclaratif : on laisse mutableUsers = true
    # (défaut NixOS), donc les mots de passe se posent/modifient à la main avec
    # `passwd` et persistent aux rebuilds.

    # CHECKS
    assertions = [
      {
        assertion = lib.any (user: user.isAdmin) config.systemSettings.users;
        message = "Erreur : il faut au moins un utilisateur avec isAdmin = true (wheel) !";
      }
      {
        assertion = lib.length config.systemSettings.users > 0;
        message = "Erreur : la liste des utilisateurs ne peut pas être vide !";
      }
    ];

    users.users = builtins.listToAttrs
      (map (user: {
        name = user.name;
        value = {
          isNormalUser = true;
          extraGroups = [ "networkmanager" "video" "render" "libvirtd" ] ++ lib.optional user.isAdmin "wheel" ++ lib.optional user.allowDocker "docker";
          createHome = true;
          description = user.name;
        };
      }) config.systemSettings.users);

    home-manager.users = builtins.listToAttrs
      (map (user: {
        name = user.name;
        value = {
          home.username = user.name;
          home.homeDirectory = "/home/"+user.name;
        };
      }) config.systemSettings.users);
  };
}
