{
  config,
  lib,
  pkgs-unstable,
  myLib,
  ...
}:

let
  inherit (config.home) homeDirectory;
  cfg = config.userSettings.dev.vercelCli;

  vercelTarball = myLib.packaging.fetchPinned cfg.pkgs ./pinned.json;

  vercel-wrapper = myLib.sops.mkSecretEnvWrapper {
    inherit config;
    pkgs = cfg.pkgs;
    name = "vercel";
    secret = cfg.tokenSops;
    envVar = "VERCEL_TOKEN";
    exec = "${cfg.pkgs.nodejs_22}/bin/npx --yes file://${vercelTarball}";
  };

  pluginPinned = builtins.fromJSON (builtins.readFile ./claude-plugin/pinned.json);

  vercelPluginSrc = cfg.pkgs.fetchFromGitHub {
    owner = "vercel";
    repo = "vercel-plugin";
    inherit (pluginPinned) rev hash;
  };
in
{
  options.userSettings.dev.vercelCli = {
    enable = lib.mkEnableOption "Vercel CLI";
    pkgs = myLib.mkPkgsOption {
      inherit lib config;
      default = pkgs-unstable;
    };

    tokenSops = lib.mkOption {
      type = lib.types.str;
      default = "vercel/token";
      description = ''
        Nom du secret sops contenant le token Vercel.
        A renseigner via `secrets edit <ce nom>`.
      '';
    };

    claudePlugin.enable = lib.mkEnableOption "plugin Claude Code officiel Vercel (commandes + subagents deploiement, portee user)";
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = myLib.sops.assertAvailable {
          inherit config;
          optionName = "userSettings.dev.vercelCli";
          need = "a besoin du secret sops (token Vercel)";
        };

        home.packages = [ vercel-wrapper ];

        sops.secrets.${cfg.tokenSops} = { };
      }

      # Deep-merge dans installed_plugins.json (qui liste d'autres plugins).
      (lib.mkIf cfg.claudePlugin.enable (
        let
          jsonFormat = cfg.pkgs.formats.json { };
          installedPluginsFile = jsonFormat.generate "vercel-claude-plugin.json" {
            version = 2;
            plugins."vercel@claude-plugins-official" = [
              {
                scope = "user";
                installPath = "${vercelPluginSrc}";
                version = pluginPinned.version;
                installedAt = pluginPinned.pinnedAt;
                lastUpdated = pluginPinned.pinnedAt;
              }
            ];
          };
        in
        {
          home.activation.vercelClaudePlugin = lib.hm.dag.entryAfter [ "writeBoundary" ] (
            myLib.deepMergeJsonActivation {
              inherit lib;
              pkgs = cfg.pkgs;
              targetPath = "${homeDirectory}/.claude/plugins/installed_plugins.json";
              sourceFile = installedPluginsFile;
              label = "vercel-claude-plugin";
            }
          );

          userSettings.agents.claude.settings.enabledPlugins."vercel@claude-plugins-official" = true;
        }
      ))
    ]
  );
}
