{
  config,
  lib,
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
        description = ''
          Autorise l'ouverture de session par mot de passe. `false` (défaut) =
          clés uniquement : un mot de passe se bruteforce et se rejoue, une
          clé non. Les clés autorisées se déclarent par utilisateur, dans
          `systemSettings.users.*.sshKeys`.
        '';
      };

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Ouvre le port dans le pare-feu (activé par défaut, cf. modules/system/configuration.nix).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # Cas typique : profil serveur écrit d'un bloc, sshKeys oublié. La
        # machine build, boote, et n'accepte plus une seule connexion — sur
        # un host distant ça se découvre quand il est déjà trop tard.
        assertion = cfg.passwordAuthentication || keyedUsers != [ ];
        message = "systemSettings.ssh : aucun utilisateur n'a de sshKeys et passwordAuthentication est faux — plus personne ne pourrait ouvrir de session SSH. Renseigne systemSettings.users.*.sshKeys.";
      }
    ];

    services.openssh = {
      enable = true;
      ports = [ cfg.port ];
      inherit (cfg) openFirewall;

      settings = {
        PasswordAuthentication = cfg.passwordAuthentication;
        # Le clavier-interactif est l'autre porte vers PAM (donc vers le mot
        # de passe) : la laisser ouverte annulerait le réglage ci-dessus.
        KbdInteractiveAuthentication = cfg.passwordAuthentication;
        # On se connecte en nchpg (wheel) puis sudo : une session root
        # directe ne laisse aucune trace de QUI a agi.
        PermitRootLogin = "no";
      };
    };
  };
}
