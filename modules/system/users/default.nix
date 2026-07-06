{
  config,
  lib,
  pkgs-stable,
  ...
}:

{
  options = {
    systemSettings = {
      users = lib.mkOption {
        description = "List of desktop users to create on the system";
        type = lib.types.listOf (
          lib.types.submodule {
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
              allowLibvirt = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "If true, the user will be in the libvirtd group (VM management, quasi root-equivalent)";
              };
              shell = lib.mkOption {
                type = lib.types.nullOr (
                  lib.types.enum [
                    "bash"
                    "zsh"
                    "fish"
                  ]
                );
                default = null;
                description = ''
                  Shell de LOGIN (TTY, SSH). null = bash (défaut NixOS).
                  Les terminaux graphiques, eux, suivent userSettings.shell.default
                  (home-manager) — avant cette option, un login TTY/SSH tombait
                  toujours sur bash même avec fish configuré partout ailleurs.
                '';
              };
            };
          }
        );
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

    users.users = builtins.listToAttrs (
      map (user: {
        inherit (user) name;
        value = {
          isNormalUser = true;
          # libvirtd n'est PAS dans la base commune : le groupe est quasi
          # équivalent root (une VM peut monter le disque hôte) → opt-in,
          # comme docker.
          extraGroups = [
            "networkmanager"
            "video"
            "render"
          ]
          ++ lib.optional user.isAdmin "wheel"
          ++ lib.optional user.allowDocker "docker"
          ++ lib.optional user.allowLibvirt "libvirtd";
          shell = lib.mkIf (user.shell != null) pkgs-stable.${user.shell};
          createHome = true;
          description = user.name;
        };
      }) config.systemSettings.users
    );

    # Un shell de login ≠ bash doit être activé côté système : ça l'ajoute à
    # /etc/shells (sinon le login est refusé) et fournit les complétions des
    # paquets système.
    programs.fish.enable = lib.any (user: user.shell == "fish") config.systemSettings.users;
    programs.zsh.enable = lib.any (user: user.shell == "zsh") config.systemSettings.users;

    home-manager.users = builtins.listToAttrs (
      map (user: {
        inherit (user) name;
        value = {
          home.username = user.name;
          home.homeDirectory = "/home/" + user.name;
        };
      }) config.systemSettings.users
    );
  };
}
