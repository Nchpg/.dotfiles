{
  config,
  lib,
  inputs,
  ...
}:

# Réglages Claude Code déclaratifs.
#
# Subtilité : Claude Code ÉCRIT lui-même dans ~/.claude/settings.json (modèle via
# /model, thème via /config, etc.). Un symlink lecture-seule du store casserait
# ces écritures. On fait donc un DEEP-MERGE au rebuild : on impose seulement les
# clés de `settings` (elles sont déclaratives → ré-appliquées à chaque rebuild),
# tout le reste que Claude gère au runtime est préservé.
let
  inherit (config.home) homeDirectory;
  cfg = config.userSettings.claude;
  jsonFormat = cfg.pkgs.formats.json { };
  settingsFile = jsonFormat.generate "claude-settings.json" cfg.settings;
in
{
  options.userSettings.claude = {
    enable = lib.mkEnableOption "réglages Claude Code déclaratifs (~/.claude/settings.json)";

    statusline.enable = lib.mkEnableOption "statusline maison (modèle, coût, contexte, rate limits)";

    pkgs = lib.mkOption {
      type = lib.types.pkgs;
      default = config.userSettings.defaultPkgs;
      description = "Pkgs to use";
    };

    settings = lib.mkOption {
      inherit (jsonFormat) type;
      default = { };
      example = {
        preferredNotifChannel = "notifications_disabled";
      };
      description = ''
        Clés imposées dans ~/.claude/settings.json. Fusionnées (deep-merge) dans
        le fichier existant à chaque rebuild : ces clés sont déclaratives (le
        rebuild les ré-applique), tandis que les autres réglages que Claude Code
        écrit lui-même (modèle, thème…) sont conservés.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        home.packages = [
          # Claude Code via le flake dédié (toujours à jour, cf. flake.nix ;
          # bump avec `rebuild -u`).
          inputs.claude-code.packages.x86_64-linux.default
          # pdftoppm (PDF -> image) et pdftotext, utilisés par la lecture de PDF.
          cfg.pkgs.poppler-utils
        ];

        # Skills Claude Code déclaratifs : chaque dossier de ./skills devient
        # ~/.claude/skills/<nom> (symlink du store — Claude ne fait que les
        # lire, contrairement à settings.json). Les skills ajoutés à la main
        # dans ~/.claude/skills/ cohabitent sans conflit.
        home.file = lib.mapAttrs' (
          name: _type: lib.nameValuePair ".claude/skills/${name}" { source = ./skills + "/${name}"; }
        ) (lib.filterAttrs (_name: type: type == "directory") (builtins.readDir ./skills));
      }

      # Statusline : barre du bas de Claude Code (modèle · coût · jauge de
      # contexte · rate limits 5 h / 7 j avec compte à rebours). La logique vit
      # dans ./statusline.js ; le wrapper épingle SON node (le `node` du PATH
      # n'est qu'une dépendance implicite d'autres modules — nodejs-slim est
      # déjà dans le profil, donc aucun poids ajouté). La clé statusLine passe
      # par le deep-merge de `settings` ci-dessous.
      (lib.mkIf cfg.statusline.enable {
        userSettings.claude.settings.statusLine = {
          type = "command";
          command = "${homeDirectory}/.claude/statusline.sh";
        };
        home.file.".claude/statusline.sh".source = cfg.pkgs.writeShellScript "claude-statusline" ''
          exec ${cfg.pkgs.nodejs-slim}/bin/node ${./statusline.js} "$@"
        '';
      })

      (lib.mkIf (cfg.settings != { }) {
        home.activation.claudeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] (
          import ../../../lib/deep-merge-json-activation.nix {
            inherit lib;
            pkgs = cfg.pkgs;
            targetPath = "${homeDirectory}/.claude/settings.json";
            sourceFile = settingsFile;
            label = "claude";
          }
        );
      })
    ]
  );
}
