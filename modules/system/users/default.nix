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
              sshKeys = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = ''
                  Clés PUBLIQUES autorisées à ouvrir une session SSH sous cet
                  utilisateur (~/.ssh/authorized_keys). Publiques : rien à
                  protéger, elles restent en clair dans le repo — contrairement
                  aux secrets, qui passent par sops.

                  Sans effet tant que systemSettings.ssh.enable est faux.
                '';
                example = [ "ssh-ed25519 AAAAC3Nza… nchpg@gram" ];
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

    # Binaire sudo exécutable par le seul groupe wheel : un compte non admin
    # (guest, utilisateurs de service) ne peut même pas tenter une élévation.
    # Rien d'autre que l'admin n'appelle sudo (ni service, ni CI).
    security.sudo.execWheelOnly = true;

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
          # système (policy polkit modify.system). Conditionné à NM, sinon le
          # groupe n'existe pas (profil à IP statique, cf. modules/system/network).
          # video/render pour tous : accès GPU (luminosité, Vulkan, VA-API),
          # pas un souci sur une machine mono-user de confiance. libvirtd reste
          # opt-in comme docker : quasi équivalent root (une VM peut monter le
          # disque hôte).
          extraGroups = [
            "video"
            "render"
          ]
          ++ lib.optional config.networking.networkmanager.enable "networkmanager"
          ++ lib.optional user.isAdmin "wheel"
          ++ lib.optional user.allowDocker "docker"
          ++ lib.optional user.allowLibvirt "libvirtd";
          shell = lib.mkIf (user.shell != null) pkgs-stable.${user.shell};
          openssh.authorizedKeys.keys = user.sshKeys;
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
