{ config, lib, inputs, ... }:

# Réglages Claude Code déclaratifs.
#
# Subtilité : Claude Code ÉCRIT lui-même dans ~/.claude/settings.json (modèle via
# /model, thème via /config, etc.). Un symlink lecture-seule du store casserait
# ces écritures. On fait donc un DEEP-MERGE au rebuild : on impose seulement les
# clés de `settings` (elles sont déclaratives → ré-appliquées à chaque rebuild),
# tout le reste que Claude gère au runtime est préservé.
let
  cfg = config.userSettings.claude;
  jsonFormat = cfg.pkgs.formats.json { };
  settingsFile = jsonFormat.generate "claude-settings.json" cfg.settings;
in {
  options.userSettings.claude = {
    enable = lib.mkEnableOption "réglages Claude Code déclaratifs (~/.claude/settings.json)";

    pkgs = lib.mkOption {
      type = lib.types.attrs;
      default = config.userSettings.defaultPkgs;
      description = "Pkgs to use";
    };

    settings = lib.mkOption {
      type = jsonFormat.type;
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

  config = lib.mkIf cfg.enable (lib.mkMerge [
  {
    home.packages = [
      # Claude Code via le flake dédié (toujours à jour, cf. flake.nix ;
      # bump avec `rebuild -u`).
      inputs.claude-code.packages.x86_64-linux.default
      # pdftoppm (PDF -> image) et pdftotext, utilisés par la lecture de PDF.
      cfg.pkgs.poppler-utils
    ];
  }

  (lib.mkIf (cfg.settings != { }) {
    home.activation.claudeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p "$HOME/.claude"
      if [ -s "$HOME/.claude/settings.json" ]; then
        # deep-merge : existant (.[0]) * nos clés (.[1]) — les nôtres l'emportent.
        ${cfg.pkgs.jq}/bin/jq -s '.[0] * .[1]' \
          "$HOME/.claude/settings.json" ${settingsFile} \
          > "$HOME/.claude/settings.json.hm-tmp" \
          && mv "$HOME/.claude/settings.json.hm-tmp" "$HOME/.claude/settings.json"
      else
        install -m644 ${settingsFile} "$HOME/.claude/settings.json"
      fi
    '';
  })
  ]);
}
