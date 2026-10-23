{
  config,
  lib,
  myLib,
  pkgs-stable,
  ...
}:

let
  cfg = config.systemSettings.ssh;

  keyedUsers = lib.filter (user: user.sshKeys != [ ]) config.systemSettings.users;
in
{
  options = {
    systemSettings.ssh = {
      enable = lib.mkEnableOption "serveur OpenSSH (sshd)";

      port = lib.mkOption {
        type = lib.types.port;
        default = 22;
        description = "Port d'écoute de sshd.";
      };

      passwordAuthentication = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Autorise la connexion par mot de passe. Faux : clés uniquement (systemSettings.users.*.sshKeys).";
      };

      x11Forwarding = lib.mkEnableOption ''
        le forwarding X11 et xclip : Ctrl+V d'image dans un Claude Code distant
        lit le presse-papier local (client `ssh -Y`)
      '';

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Ouvre le port dans le pare-feu, sur `network.internalIifnames` si défini.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (lib.mkIf cfg.openFirewall (myLib.server.mkInternalPorts config { tcp = [ cfg.port ]; }))

      {
        assertions = [
          {
            # Sinon plus personne ne pourrait ouvrir de session.
            assertion = cfg.passwordAuthentication || keyedUsers != [ ];
            message = "systemSettings.ssh : aucun utilisateur n'a de sshKeys et passwordAuthentication est faux — plus personne ne pourrait ouvrir de session SSH. Renseigne systemSettings.users.*.sshKeys.";
          }
        ];

        services.openssh = {
          enable = true;
          ports = [ cfg.port ];
          openFirewall = false;

          settings = {
            PasswordAuthentication = cfg.passwordAuthentication;
            # L'autre porte vers PAM.
            KbdInteractiveAuthentication = cfg.passwordAuthentication;
            PermitRootLogin = "no";
            # COLORTERM ne traverse pas SSH : sans lui les TUI retombent en 256 couleurs.
            SetEnv = "COLORTERM=truecolor";
            X11Forwarding = cfg.x11Forwarding;
          };
        };
      }

      (lib.mkIf cfg.x11Forwarding { environment.systemPackages = [ pkgs-stable.xclip ]; })
    ]
  );
}
