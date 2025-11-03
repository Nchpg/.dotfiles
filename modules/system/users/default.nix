{ config, lib, pkgs-stable, ... }:

let
  mergeHashed = user:
    let
      filtered = lib.filter (m: m.name == user.name) config.systemSettings.users-mapping;
      mappingEntry = if lib.length filtered > 0 then lib.head filtered else null;
    in
      if user.hashedPassword != null then user
      else if mappingEntry != null then user // { hashedPassword = mappingEntry.hashedPassword; }
      else user;

  mergedUsersList = map mergeHashed config.systemSettings.users;
in
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
            hashedPassword = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Hashed password for the user";
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

      users-mapping = lib.mkOption {
        description = "Mapping of user and hashpasswod (for private module)";
        type = lib.types.listOf (lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Username";
            };
            hashedPassword = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Hashed password for the user";
            };
          };
        });
        default = [];
      };

      verify_all_users_have_passwd = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Verify before rebuild that each user have a hashpassword in the config"; 
      };
    };
  };

  config = { 
    # CHECKS
    assertions = [
      {
        assertion = lib.any (user: user.isAdmin) config.systemSettings.users;
        message = "Erreur : il faut au moins un utilisateur avec isAdmin = true (wheel) !";
      }
      {
        assertion = (lib.all (m: lib.any (u: u.name == m.name) config.systemSettings.users) config.systemSettings.users-mapping);
        message = "Erreur : tous les usernames dans users-mapping doivent exister dans systemSettings.users !";
      }
      {
        assertion = lib.length config.systemSettings.users > 0;
        message = "Erreur : la liste des utilisateurs ne peut pas être vide !";
      }
    ] ++ (if config.systemSettings.verify_all_users_have_passwd then [
      {
        assertion = lib.all (u: u.hashedPassword != null) mergedUsersList;
        message = "Erreur : tous les utilisateurs doivent avoir un hashedPassword défini dans la configuration !";
      }
    ] else []);

    users.users = builtins.listToAttrs
      (map (user: {
        name = user.name;
        value = {
          isNormalUser = true;
          extraGroups = [ "networkmanager"] ++ lib.optional user.isAdmin "wheel" ++ lib.optional user.allowDocker "docker";
          createHome = true;
          description = user.name;
          hashedPassword = lib.mkIf (user.hashedPassword != null) user.hashedPassword;
        };
      }) mergedUsersList);
    
    home-manager.users = builtins.listToAttrs
      (map (user: {
        name = user.name;
        value = {
          home.username = user.name;
          home.homeDirectory = "/home/"+user.name;
        };
      }) mergedUsersList);
  };
}