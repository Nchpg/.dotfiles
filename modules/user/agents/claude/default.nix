{
  config,
  lib,
  inputs,
  myLib,
  ...
}:

# Claude Code écrit dans ~/.claude/settings.json : deep-merge plutôt que symlink lecture-seule.
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

    screenshots.enable = lib.mkEnableOption "affichage dans feh des images renvoyées par les outils MCP (captures)";

    playwright.enable = lib.mkEnableOption "serveur MCP Playwright (navigateur headless)";

    pkgs = myLib.mkPkgsOption { inherit lib config; };

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
          inputs.claude-code.packages.${cfg.pkgs.stdenv.hostPlatform.system}.default
          cfg.pkgs.poppler-utils
        ];
      }

      (lib.mkIf cfg.statusline.enable {
        userSettings.agents.claude.settings.statusLine = {
          type = "command";
          command = "${homeDirectory}/.claude/statusline.sh";
        };
        home.file.".claude/statusline.sh".source = cfg.pkgs.writeShellScript "claude-statusline" ''
          exec ${cfg.pkgs.nodejs-slim}/bin/node ${./statusline.js} "$@"
        '';
      })

      (lib.mkIf cfg.screenshots.enable {
        userSettings.agents.claude.settings.hooks.PostToolUse = [
          {
            # Read : les images que Claude ouvre lui-même (captures grim, fichiers PNG…).
            matcher = "mcp__.*|Read";
            hooks = [
              {
                type = "command";
                command = "${homeDirectory}/.claude/hooks/show-screenshot.sh";
              }
            ];
          }
        ];
        # Les deux scripts restent dans le même dossier : le hook lance le gardien à côté de lui.
        home.file.".claude/hooks/show-screenshot.sh".source =
          cfg.pkgs.writeShellScript "claude-show-screenshot" ''
            export PATH=${
              lib.makeBinPath [
                cfg.pkgs.feh
                cfg.pkgs.procps
              ]
            }:$PATH
            exec ${lib.getExe cfg.pkgs.python3} -I ${./screenshots}/show-screenshot.py
          '';

        # Le hook pose la fenêtre sur le workspace du terminal de Claude.
        home.file.".config/sway/conf.d/claude-screenshots.conf" =
          lib.mkIf config.userSettings.windowManager.sway.enable
            {
              text = ''
                for_window [title="^claude-screenshot"] floating enable, resize set 1500 830, move position center, border pixel 1
              '';
            };
      })

      (lib.mkIf cfg.playwright.enable {
        # --isolated : sans lui, le profil navigateur est créé à côté des navigateurs, dans le store.
        # --output-dir : sinon .playwright-mcp/ atterrit dans le repo courant.
        home.file.".claude/mcp/playwright.sh".source = cfg.pkgs.writeShellScript "claude-playwright-mcp" ''
          exec ${lib.getExe cfg.pkgs.playwright-mcp} --headless --isolated \
            --output-dir "''${XDG_RUNTIME_DIR:-/tmp}/playwright-mcp" "$@"
        '';

        # Serveurs MCP de portée utilisateur : ~/.claude.json, pas settings.json.
        home.activation.claudeMcpServers = lib.hm.dag.entryAfter [ "writeBoundary" ] (
          myLib.deepMergeJsonActivation {
            inherit lib;
            pkgs = cfg.pkgs;
            targetPath = "${homeDirectory}/.claude.json";
            sourceFile = jsonFormat.generate "claude-mcp-servers.json" {
              mcpServers.playwright = {
                type = "stdio";
                command = "${homeDirectory}/.claude/mcp/playwright.sh";
                args = [ ];
                env = { };
              };
            };
            label = "claude-mcp";
          }
        );
      })

      (lib.mkIf (cfg.settings != { }) {
        home.activation.claudeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] (
          myLib.deepMergeJsonActivation {
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
