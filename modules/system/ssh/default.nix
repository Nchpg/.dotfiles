{
  config,
  lib,
  myLib,
  pkgs-stable,
  ...
}:

let
  cfg = config.systemSettings.ssh;

  keyedUsers = lib.filter (keys: keys != [ ]) (lib.attrValues cfg.authorizedKeys);

  fileKeys = if cfg.keysFile == null then { } else lib.importJSON cfg.keysFile;
  userNames = map (u: u.name) config.systemSettings.users;
  rePubKey = "(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\\.com|sk-ecdsa-sha2-nistp256@openssh\\.com) [A-Za-z0-9+/]+={0,3}( [^\"\\]{0,100})?";
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

      waypipe = lib.mkEnableOption ''
        waypipe et wl-clipboard : via waypipe (userSettings.ssh.waypipe.hosts côté client),
        `wl-paste` (et donc Ctrl+V d'image dans Claude Code) lit le presse-papier du poste client
      '';

      keysFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        example = lib.literalExpression "./ssh-keys.json";
        description = ''
          Clés autorisées en données, `{ "<compte>": [ "ssh-ed25519 AAAA… commentaire" ] }`, en plus des
          `systemSettings.users.*.sshKeys` : le dashboard les ajoute par commit (jamais appliqué seul,
          `rebuild` les montre et demande confirmation).
        '';
      };

      authorizedKeys = lib.mkOption {
        type = lib.types.attrsOf (lib.types.listOf lib.types.str);
        readOnly = true;
        default = lib.listToAttrs (
          map (
            u: lib.nameValuePair u.name (u.sshKeys ++ fileKeys.${u.name} or [ ])
          ) config.systemSettings.users
        );
        defaultText = lib.literalExpression "sshKeys de chaque compte, plus celles de keysFile";
        description = "Clés autorisées de chaque compte (Nix et keysFile).";
      };

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

      # Relu par `rebuild` avant d'activer (le dashboard l'écrit).
      (lib.mkIf (cfg.keysFile != null) {
        systemSettings.accessReview.files.ssh-keys = {
          source = cfg.keysFile;
          kind = "ssh";
        };
      })

      {
        assertions = [
          {
            assertion = lib.all (n: lib.elem n userNames) (lib.attrNames fileKeys);
            message = "systemSettings.ssh.keysFile : compte(s) inconnu(s) ${toString (lib.subtractLists userNames (lib.attrNames fileKeys))}.";
          }
          {
            assertion = lib.all (k: builtins.match rePubKey k != null) (
              lib.concatLists (lib.attrValues fileKeys)
            );
            message = "systemSettings.ssh.keysFile : clé(s) publique(s) mal formée(s).";
          }
          {
            # Sinon plus personne ne pourrait ouvrir de session.
            assertion = cfg.passwordAuthentication || keyedUsers != [ ];
            message = "systemSettings.ssh : aucun utilisateur n'a de sshKeys et passwordAuthentication est faux — plus personne ne pourrait ouvrir de session SSH. Renseigne systemSettings.users.*.sshKeys ou keysFile.";
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
          };
        };
      }

      (lib.mkIf cfg.waypipe {
        environment.systemPackages = with pkgs-stable; [
          waypipe
          wl-clipboard
        ];
      })
    ]
  );
}
