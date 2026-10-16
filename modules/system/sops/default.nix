{
  config,
  lib,
  inputs,
  target,
  myLib,
  ...
}:

let
  cfg = config.systemSettings.sops;

  declared = lib.attrNames config.sops.secrets;

  # Par défaut la machine qui déclare ; le générateur fait l'union sur toutes les cibles.
  audience = myLib.sops.audience.audience {
    inherit (cfg) deployments secretProfiles;
    inherit (target) host;
  };

  deployedHere = lib.elem target.profile (cfg.deployments.${target.host} or [ ]);

  unreadable = lib.filter (name: !(lib.elem target.host (audience name))) declared;

in
{
  options = {
    systemSettings.sops = {
      keyOwner = lib.mkOption {
        type = lib.types.str;
        example = "nchpg";
        description = ''
          Utilisateur qui détient la clé age ; les autres users (dont root) la réutilisent.
        '';
      };

      deployments = lib.mkOption {
        type = lib.types.attrsOf (lib.types.listOf lib.types.str);
        default = { };
        example = {
          think = [ "server" ];
          gram = [ "personal" ];
        };
        description = ''
          Profils actifs par machine ; seule cette table dit quelles cibles sont déployées
          et pour qui sceller les secrets.
        '';
      };

      secretProfiles = lib.mkOption {
        type = lib.types.attrsOf (lib.types.listOf lib.types.str);
        default = { };
        example = {
          "wireguard/gram_preshared_key" = [
            "server"
            "personal"
          ];
        };
        description = ''
          Élargit l'audience d'un secret (par nom) à tous les hosts de ces profils.
        '';
      };
    };

    # Pas de défaut commun (un nom sans fichier fait échouer l'évaluation) ; défaut sur `sopsFile`
    # et non option parallèle, qui casserait la fusion de `restartUnits`.
    sops.secrets = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            config.sopsFile = lib.mkDefault "${inputs.secrets}/${name}.yaml";
          }
        )
      );
    };
  };

  config = {
    assertions = [
      {
        assertion = lib.any (
          user: user.name == config.systemSettings.sops.keyOwner
        ) config.systemSettings.users;
        message = "systemSettings.sops.keyOwner doit correspondre à un utilisateur déclaré dans systemSettings.users.";
      }
      {
        assertion = !deployedHere || unreadable == [ ];
        message = "systemSettings.sops : ${target.host} déclare des secrets dont elle n'est destinataire d'aucun fichier (${lib.concatStringsSep ", " unreadable}). Ajoute son profil dans systemSettings.sops.deployments, ou élargis `profiles` sur ces secrets, puis `secrets policy`.";
      }
    ];

    warnings =
      lib.optional (cfg.deployments != { } && !(cfg.deployments ? ${target.host}))
        "systemSettings.sops.deployments ne mentionne pas ${target.host} : aucun secret ne sera scellé pour cette machine. C'est normal pour une cible qu'on ne fait que construire."
      ++
        lib.optional (!deployedHere && unreadable != [ ])
          "systemSettings.sops : ${target.machine} n'est pas une cible déployée et déclare des secrets qu'elle ne pourrait pas déchiffrer (${lib.concatStringsSep ", " unreadable}). Sans conséquence tant qu'on ne fait que la construire.";

    # Clé age dédiée par machine, créée par ./init.sh (`-pq`). Pas de generateKey (clé classique,
    # affaiblit les destinataires hybrides ML-KEM-768 + X25519) ni de sshKeyPaths.
    sops = {
      defaultSopsFormat = "yaml";

      age = {
        keyFile = "/var/lib/sops-nix/key.txt";
        generateKey = false;
        sshKeyPaths = [ ];
      };
    };
  };
}
