{
  config,
  lib,
  inputs,
  ...
}:

# Fichiers d'accès que le dashboard écrit par apps.yml (sites, appareils VPN, comptes Authelia, clés
# SSH) : chaque module déclare le sien. La version active de chacun est gardée dans /etc, avec la
# liste ; avant d'activer, `rebuild` la compare au dépôt, montre ce qui change et demande confirmation.
let
  cfg = config.systemSettings.accessReview;

  # Chemin dans le dépôt : `/nix/store/…-source/profiles/server/apps.json` -> `profiles/server/apps.json`.
  inRepo = file: lib.removePrefix "${toString inputs.self}/" (toString file);
in
{
  options.systemSettings.accessReview.files = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          source = lib.mkOption {
            type = lib.types.path;
            description = "Le fichier, dans le dépôt.";
          };
          kind = lib.mkOption {
            type = lib.types.enum [
              "apps"
              "vpn"
              "authelia"
              "ssh"
            ];
            description = "Format, pour le résumé de `rebuild`.";
          };
        };
      }
    );
    default = { };
    description = "Fichiers d'accès écrits hors de ce dépôt local (dashboard, apps.yml), relus par `rebuild`.";
  };

  config = lib.mkIf (cfg.files != { }) {
    environment.etc =
      lib.mapAttrs' (
        name: f: lib.nameValuePair "dotfiles/access/${name}.json" { inherit (f) source; }
      ) cfg.files
      // {
        "dotfiles/access.json".text = builtins.toJSON (
          lib.mapAttrsToList (name: f: {
            inherit name;
            inherit (f) kind;
            path = inRepo f.source;
            active = "/etc/dotfiles/access/${name}.json";
          }) cfg.files
        );
      };
  };
}
