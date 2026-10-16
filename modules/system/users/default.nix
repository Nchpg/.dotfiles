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
        description = "List of users to create on the system";
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
                description = "Clés publiques autorisées en SSH (authorized_keys). Sans effet tant que systemSettings.ssh.enable est faux.";
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
                description = "Shell de login (TTY, SSH). null = bash. Les terminaux graphiques suivent userSettings.shell.default.";
              };
            };
          }
        );
      };
    };
  };

  config = {

    security.sudo.execWheelOnly = true;

    assertions = [
      {
        assertion = lib.any (user: user.isAdmin) config.systemSettings.users;
        message = "Erreur : il faut au moins un utilisateur avec isAdmin = true (wheel) !";
      }
    ];

    users.users = builtins.listToAttrs (
      map (user: {
        inherit (user) name;
        value = {
          isNormalUser = true;
          # networkmanager seulement si NM est actif ; libvirtd et docker restent opt-in (quasi root).
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

    # Ajoute le shell à /etc/shells (sinon login refusé).
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
