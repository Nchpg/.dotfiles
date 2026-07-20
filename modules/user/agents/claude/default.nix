{
  config,
  lib,
  inputs,
  ...
}:

# Claude Code ÉCRIT lui-même dans ~/.claude/settings.json (modèle, thème...) :
# un symlink lecture-seule casserait ces écritures. Deep-merge au rebuild à
# la place (cf. `settings` plus bas).
let
  inherit (config.home) homeDirectory;
  cfg = config.userSettings.agents.claude;
  jsonFormat = cfg.pkgs.formats.json { };
  settingsFile = jsonFormat.generate "claude-settings.json" cfg.settings;
in
{
  options.userSettings.agents.claude = {
    enable = lib.mkEnableOption "réglages Claude Code déclaratifs (~/.claude/settings.json)";

    statusline.enable = lib.mkEnableOption "statusline maison (modèle, coût, contexte, rate limits)";

    pkgs = import ../../../../lib/mk-pkgs-option.nix { inherit lib config; };

    settings = lib.mkOption {
      inherit (jsonFormat) type;
      default = { };
      example = {
        preferredNotifChannel = "notifications_disabled";
      };
      description = "Clés imposées dans ~/.claude/settings.json (deep-merge à chaque rebuild).";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        home.sessionVariables = {
          NODE_OPTIONS = "--dns-result-order=ipv4first";
        };

        home.packages = [
          # Flake dédié, toujours à jour (bump via `rebuild -u`).
          inputs.claude-code.packages.${cfg.pkgs.stdenv.hostPlatform.system}.default
          cfg.pkgs.poppler-utils # pdftoppm/pdftotext, lecture de PDF
        ];
      }

      # Logique dans ./statusline.js, wrapper épinglant nodejs-slim (déjà
      # dans le profil, pas de poids ajouté).
      (lib.mkIf cfg.statusline.enable {
        userSettings.agents.claude.settings.statusLine = {
          type = "command";
          command = "${homeDirectory}/.claude/statusline.sh";
        };
        home.file.".claude/statusline.sh".source = cfg.pkgs.writeShellScript "claude-statusline" ''
          exec ${cfg.pkgs.nodejs-slim}/bin/node ${./statusline.js} "$@"
        '';
      })

      (lib.mkIf (cfg.settings != { }) {
        home.activation.claudeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] (
          import ../../../../lib/deep-merge-json-activation.nix {
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
