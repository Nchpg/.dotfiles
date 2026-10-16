{
  config,
  lib,
  pkgs-stable,
  ...
}:

let
  fishUsers = map (user: user.name) (
    lib.filter (user: user.shell == "fish") config.systemSettings.users
  );
in
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
                description = "Shell de login (TTY, SSH). null = bash. fish : login en bash, fish pour les sessions interactives. Les terminaux graphiques suivent userSettings.shell.default.";
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
          shell = lib.mkIf (user.shell != null && user.shell != "fish") pkgs-stable.${user.shell};
          openssh.authorizedKeys.keys = user.sshKeys;
          createHome = true;
          description = user.name;
        };
      }) config.systemSettings.users
    );

    # Intégration système du shell (/etc/shells, complétions des paquets).
    programs.fish.enable = lib.any (user: user.shell == "fish") config.systemSettings.users;
    programs.zsh.enable = lib.any (user: user.shell == "zsh") config.systemSettings.users;

    # Un script sh envoyé par SSH (VS Code Remote, outils de déploiement) échoue dans fish :
    # login en bash, et seul un bash de login interactif passe la main à fish.
    programs.bash.interactiveShellInit = lib.mkIf (fishUsers != [ ]) ''
      if shopt -q login_shell && [ -z "''${BASH_EXECUTION_STRING:-}" ]; then
        case " ${lib.concatStringsSep " " fishUsers} " in
          *" $USER "*) exec ${lib.getExe config.programs.fish.package} --login ;;
        esac
      fi
    '';

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
