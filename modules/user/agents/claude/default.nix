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

    ponytail.enable = lib.mkEnableOption "plugin ponytail (YAGNI, la solution la plus courte qui marche)";

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

      # Plugin épinglé dans le store : installed_plugins.json pointe dessus, la marketplace
      # est déclarée pour que Claude Code ne le considère pas orphelin. Les hooks lancent `node`.
      (lib.mkIf cfg.ponytail.enable (
        let
          pinned = builtins.fromJSON (builtins.readFile ./ponytail/pinned.json);
          upstream = cfg.pkgs.fetchFromGitHub {
            owner = "DietrichGebert";
            repo = "ponytail";
            inherit (pinned) rev hash;
          };
          # Sans la barre sous le prompt (mode, coût, boutons) ni son journal CSV : on retire
          # claude-band.json des hooks. jq échoue si l'entrée a disparu en amont.
          src = cfg.pkgs.runCommand "ponytail-${pinned.version}" { nativeBuildInputs = [ cfg.pkgs.jq ]; } ''
            cp -r ${upstream} $out
            chmod -R u+w $out
            jq -e '.hooks | index("./hooks/claude-band.json")' $out/.claude-plugin/plugin.json >/dev/null
            jq '.hooks -= ["./hooks/claude-band.json"]' ${upstream}/.claude-plugin/plugin.json \
              >$out/.claude-plugin/plugin.json
          '';
        in
        {
          home.packages = [ cfg.pkgs.nodejs-slim ];

          home.activation.claudePonytailPlugin = lib.hm.dag.entryAfter [ "writeBoundary" ] (
            myLib.deepMergeJsonActivation {
              inherit lib;
              pkgs = cfg.pkgs;
              targetPath = "${homeDirectory}/.claude/plugins/installed_plugins.json";
              sourceFile = jsonFormat.generate "ponytail-claude-plugin.json" {
                version = 2;
                plugins."ponytail@ponytail" = [
                  {
                    scope = "user";
                    installPath = "${src}";
                    inherit (pinned) version;
                    installedAt = pinned.pinnedAt;
                    lastUpdated = pinned.pinnedAt;
                  }
                ];
              };
              label = "ponytail-claude-plugin";
            }
          );

          userSettings.agents.claude.settings = {
            extraKnownMarketplaces.ponytail.source = {
              source = "github";
              repo = "DietrichGebert/ponytail";
            };
            enabledPlugins."ponytail@ponytail" = true;
          };
        }
      ))

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
