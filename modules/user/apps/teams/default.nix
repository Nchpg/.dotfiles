{
  config,
  lib,
  myLib,
  ...
}:

# Une instance par tenant : le switcher d'orga de Teams v2 boucle sur un tenant invité.
let
  cfg = config.userSettings.apps.teams;

  baseBin = "${cfg.pkgs.teams-for-linux}/bin/teams-for-linux";
  argsStr = lib.concatMapStringsSep " " lib.escapeShellArg cfg.extraArgs;

  trayIcon = "${./teams.png}";
  jsonFormat = cfg.pkgs.formats.json { };
  configFile = jsonFormat.generate "teams-for-linux-config.json" cfg.settings;

  profileUrl =
    p:
    if p.url != null then
      p.url
    else if p.tenantId != null then
      "https://teams.cloud.microsoft/v2/?tenantId=${p.tenantId}"
    else
      null;

  mainCmd = cfg.pkgs.writeShellScriptBin "teams" ''
    exec ${baseBin} \
      --class=teams \
      --appTitle=${lib.escapeShellArg cfg.title} \
      --appIcon=${lib.escapeShellArg trayIcon} \
      ${argsStr} "$@"
  '';

  mkProfile =
    name: p:
    let
      url = profileUrl p;
      title = if p.title != null then p.title else "Teams (${name})";
    in
    cfg.pkgs.writeShellScriptBin "teams-${name}" ''
      exec ${baseBin} \
        --user-data-dir="$HOME/.config/teams-for-linux-${name}" \
        --class="teams-${name}" \
        --appTitle=${lib.escapeShellArg title} \
        --appIcon=${lib.escapeShellArg trayIcon} \
        ${lib.optionalString (url != null) "--url=${lib.escapeShellArg url}"} \
        ${argsStr} "$@"
    '';

  mkDesktop = wmClass: title: exec: {
    name = title;
    genericName = "Microsoft Teams";
    inherit exec;
    icon = "teams";
    terminal = false;
    startupNotify = true;
    categories = [
      "Network"
      "InstantMessaging"
    ];
    settings.StartupWMClass = wmClass;
  };
in
{
  options = {
    userSettings.apps.teams = {
      enable = lib.mkEnableOption "Microsoft Teams via teams-for-linux (wrapper Electron)";

      pkgs = myLib.mkPkgsOption { inherit lib config; };

      title = lib.mkOption {
        type = lib.types.str;
        default = "Teams";
        description = "Titre de l'instance principale (`--appTitle`).";
      };

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "--ozone-platform-hint=auto"
          # WaylandWindowDecorations : rendu natif (sinon flou/XWayland).
          # WebRTCPipeWireCapturer : partage d'écran via le portail PipeWire.
          "--enable-features=WaylandWindowDecorations,WebRTCPipeWireCapturer"
        ];
        description = "Flags Electron de l'instance principale et des `profiles`.";
      };

      settings = lib.mkOption {
        inherit (jsonFormat) type;
        default = {
          # Sinon effet miroir quand on partage l'écran qu'on regarde.
          screenSharing.thumbnail.enabled = false;
        };
        example = {
          screenSharing.thumbnail.enabled = true;
        };
        description = "`config.json` de teams-for-linux, déployé dans chaque instance (principale + profiles).";
      };

      profiles = lib.mkOption {
        default = { };
        example = lib.literalExpression ''
          { bouygues.tenantId = "00000000-0000-0000-0000-000000000000"; }
        '';
        description = ''
          Instances isolées, une par tenant : commande `teams-<nom>`, entrée de
          menu et `--user-data-dir` propres. `tenantId` ouvre directement le
          tenant (contourne le switcher cassé pour un accès invité).
        '';
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              tenantId = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = ''
                  GUID du tenant à ouvrir (deep-link `?tenantId=`), présent dans le
                  lien d'invitation (param `tenant=`) ou le champ `issuer` de
                  `https://login.microsoftonline.com/<domaine>/v2.0/.well-known/openid-configuration`.
                '';
              };
              url = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "URL de démarrage explicite (prioritaire sur `tenantId`).";
              };
              title = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Titre de l'instance (`--appTitle`) ; null => « Teams (<nom>) ».";
              };
            };
          }
        );
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ mainCmd ] ++ lib.mapAttrsToList mkProfile cfg.profiles;

    home.file = {
      ".local/share/icons/hicolor/512x512/apps/teams.png".source = ./teams.png;
      ".config/teams-for-linux/config.json".source = configFile;
    }
    // lib.mapAttrs' (
      name: _: lib.nameValuePair ".config/teams-for-linux-${name}/config.json" { source = configFile; }
    ) cfg.profiles;

    xdg.desktopEntries = {
      teams = mkDesktop "teams" "Teams" "teams %U";
    }
    // lib.mapAttrs' (
      name: _:
      lib.nameValuePair "teams-${name}" (mkDesktop "teams-${name}" "Teams (${name})" "teams-${name} %U")
    ) cfg.profiles;
  };
}
