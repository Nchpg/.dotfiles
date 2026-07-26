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

  # Version + hash épinglés automatiquement par update.sh
  pinned = builtins.fromJSON (builtins.readFile ./pinned.json);

  # Tarball npm vérifié par Nix (FOD) : pas de package "vercel" dans nixpkgs.
  vercelTarball = cfg.pkgs.fetchurl {
    url = "https://registry.npmjs.org/vercel/-/vercel-${pinned.version}.tgz";
    sha256 = pinned.sha256;
  };

  # VERCEL_TOKEN lu par le CLI lui-même (confirmé dans son bundle JS) : le
  # secret n'est jamais dans le store, seul le chemin déchiffré par sops-nix
  # (re-déchiffré à chaque activation) l'est.
  vercelTokenPath = config.sops.secrets.${cfg.tokenSops}.path;

  # npx + Node.js nixpkgs, même technique que kimi-code : file:// requis, un
  # chemin nu fait échouer npx (tente de l'exécuter direct).
  vercel-wrapper = cfg.pkgs.writeShellScriptBin "vercel" ''
    export VERCEL_TOKEN="$(cat ${vercelTokenPath})"
    exec ${cfg.pkgs.nodejs_22}/bin/npx --yes file://${vercelTarball} "$@"
  '';

  # Plugin Claude Code officiel (slash commands + subagents Vercel), épinglé
  # séparément (repo git distinct de la tarball npm ci-dessus) dans son propre
  # sous-dossier pour rester découvrable par gather-update-facts.sh (un seul
  # pinned.json par dossier).
  pluginPinned = builtins.fromJSON (builtins.readFile ./claude-plugin/pinned.json);

  vercelPluginSrc = cfg.pkgs.fetchFromGitHub {
    owner = "vercel";
    repo = "vercel-plugin";
    rev = pluginPinned.rev;
    sha256 = pluginPinned.sha256;
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
        A renseigner via `sops secrets/secrets.yaml` sous la cle correspondante.
      '';
    };

    claudePlugin.enable = lib.mkEnableOption "plugin Claude Code officiel Vercel (commandes + subagents deploiement, portee user)";
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = myLib.assertSopsAvailable {
          inherit config;
          optionName = "userSettings.dev.vercelCli";
          need = "a besoin du secret sops (token Vercel)";
        };

        home.packages = [ vercel-wrapper ];

        sops.secrets.${cfg.tokenSops} = { };
      }

      # Equivalent declaratif de `claude plugin install
      # vercel@claude-plugins-official` : entree fusionnee dans
      # ~/.claude/plugins/installed_plugins.json (deep-merge, jamais un
      # ecrasement complet — ce fichier liste tous les autres plugins
      # installes). installPath pointe directement le store Nix : contenu
      # figé/verifie (FOD), pas besoin de le copier ailleurs.
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

          # "installed" (ci-dessus) ne suffit pas : Claude Code garde l'etat
          # active/desactive a part, dans ~/.claude/settings.json
          # (enabledPlugins), deja gere en deep-merge par modules/user/agents/claude.
          userSettings.agents.claude.settings.enabledPlugins."vercel@claude-plugins-official" = true;
        }
      ))
    ]
  );
}
