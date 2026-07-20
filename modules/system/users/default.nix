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
                  Les terminaux graphiques suivent userSettings.shell.default
                  (home-manager), indépendamment de ce réglage.
                '';
              };
            };
          }
        );
      };
    };
  };

  config = {
    # Mots de passe non déclaratifs : mutableUsers = true (défaut NixOS),
    # posés/modifiés à la main via `passwd`.

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
          # networkmanager pour tous : gérer son wifi crée une connexion
          # système (policy polkit modify.system). video/render pour tous :
          # accès GPU (luminosité, Vulkan, VA-API), pas un souci sur une
          # machine mono-user de confiance. libvirtd reste opt-in comme
          # docker : quasi équivalent root (une VM peut monter le disque hôte).
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

    # Ajoute le shell à /etc/shells (sinon login refusé) + complétions système.
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
