{
  config,
  lib,
  myLib,
  ...
}:

# `teams-for-linux` (wrapper Electron non-officiel) : le switcher d'orga
# Teams v2 tourne en boucle sur un tenant invité (erreur renderer "user:1
# ... not authenticated"). Un accès invité n'est pas un compte séparé,
# c'est ta propre identité invitée chez l'autre tenant : la parade est une
# instance dédiée (`profiles`) avec son propre --user-data-dir et une URL
# deep-link ?tenantId=<GUID> qui charge Teams direct dans ce tenant.
#
# Binaire amont hors PATH/menu : wrappers `teams` (défaut) et `teams-<nom>`
# (profils) avec icône custom.
let
  cfg = config.userSettings.apps.teams;

  baseBin = "${cfg.pkgs.teams-for-linux}/bin/teams-for-linux";
  argsStr = lib.concatMapStringsSep " " lib.escapeShellArg cfg.extraArgs;

  trayIcon = "${./teams.png}"; # défaut teams-for-linux moche
  jsonFormat = cfg.pkgs.formats.json { };
  configFile = jsonFormat.generate "teams-for-linux-config.json" cfg.settings;

  # URL effective d'un profil : `url` explicite > deep-link tenant > défaut amont.
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

  # --user-data-dir garde le nom "teams-for-linux-<nom>" pour ne pas
  # invalider une session déjà connectée (le nom de l'exe seul change).
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
    # Permet à Sway/waybar d'associer la fenêtre Electron à cette entrée (donc
    # à l'icône custom) via WM_CLASS.
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
        description = ''
          Titre de l'instance principale (`--appTitle`) : sert à distinguer le
          tooltip du tray et le titre de fenêtre des instances `profiles`.
        '';
      };

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "--ozone-platform-hint=auto"
          # WaylandWindowDecorations : rendu natif (sinon flou/XWayland).
          # WebRTCPipeWireCapturer : partage d'écran via le portail PipeWire.
          "--enable-features=WaylandWindowDecorations,WebRTCPipeWireCapturer"
        ];
        description = ''
          Flags Electron passés à teams (instance principale ET instances
          déclarées dans `profiles`).
        '';
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
        description = ''
          Contenu du `config.json` de teams-for-linux, déployé dans le
          `--user-data-dir` de CHAQUE instance (principale + profiles). Voir la
          doc teams-for-linux pour les clés disponibles.
        '';
      };

      profiles = lib.mkOption {
        default = { };
        example = lib.literalExpression ''
          { bouygues.tenantId = "00000000-0000-0000-0000-000000000000"; }
        '';
        description = ''
          Instances isolées supplémentaires, une par tenant. Chaque entrée crée
          une commande `teams-<nom>` (+ une entrée de menu) avec son propre
          `--user-data-dir`. Renseigner `tenantId` (GUID du tenant) pour
          atterrir directement dans ce tenant via deep-link, ce qui contourne le
          switcher d'organisation cassé de Teams v2 (indispensable pour un accès
          invité type « Bouygues SA », où ton identité reste celle d'origine).
        '';
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              tenantId = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = ''
                  GUID du tenant Microsoft à ouvrir directement (deep-link
                  `?tenantId=`). Présent dans le lien d'invitation (param
                  `tenant=`), ou via le portail My Account, ou via
                  `https://login.microsoftonline.com/<domaine>/v2.0/.well-known/openid-configuration`
                  (champ `issuer`).
                '';
              };
              url = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = ''
                  URL de démarrage explicite (prioritaire sur `tenantId`). Laisser
                  null pour utiliser le deep-link tenant ou le défaut amont.
                '';
              };
              title = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = ''
                  Titre/nom de l'instance (`--appTitle`) affiché dans le tooltip
                  du tray et le titre de fenêtre. null => « Teams (<nom>) ».
                '';
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
