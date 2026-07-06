{ config, lib, ... }:

# Microsoft a abandonné le client Teams natif Linux. `teams-for-linux` est un
# wrapper Electron non-officiel (libre, MIT) qui reste la meilleure option
# desktop : tray, notifications et partage d'écran.
#
# Particularités gérées ici :
#   1. Electron => rendu Wayland natif + partage d'écran (portail PipeWire)
#      dépendent de flags passés au lancement (cf. `extraArgs`).
#   2. Le client Teams v2 n'arrive PAS à basculer vers un tenant invité dans
#      Electron (switcher d'orga qui tourne en boucle, erreur renderer
#      `user:1 ... not authenticated`). Un accès invité n'est PAS un compte
#      séparé : c'est ta propre identité (ex. EPITA) invitée chez l'autre
#      tenant. La parade fiable = une instance dédiée (`profiles`) avec son
#      propre `--user-data-dir` ET une URL deep-link `?tenantId=<GUID>` qui
#      charge Teams direct dans le contexte du tenant invité, sans switcher.
#
# On n'expose PAS le binaire amont `teams-for-linux` : on fournit des wrappers
# nommés `teams` (instance par défaut) et `teams-<nom>` (instances dédiées),
# avec une icône custom (cf. teams.svg). Le binaire amont reste dans la closure
# mais hors PATH/menu.
let
  cfg = config.userSettings.teams;

  baseBin = "${cfg.pkgs.teams-for-linux}/bin/teams-for-linux";
  argsStr = lib.concatMapStringsSep " " lib.escapeShellArg cfg.extraArgs;

  # Icône du tray (--appIcon) : la défaut de teams-for-linux est moche, on
  # réutilise la vraie icône Teams (teams.png) déjà embarquée dans le module.
  trayIcon = "${./teams.png}";

  # config.json de teams-for-linux (lu depuis le --user-data-dir de chaque
  # instance). Généré depuis cfg.settings, déployé dans chaque dossier.
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

  # Instance principale : commande `teams`, session par défaut
  # (~/.config/teams-for-linux, gérée par l'app amont). --appTitle distingue le
  # tooltip du tray / le titre de fenêtre quand plusieurs instances tournent.
  mainCmd = cfg.pkgs.writeShellScriptBin "teams" ''
    exec ${baseBin} \
      --class=teams \
      --appTitle=${lib.escapeShellArg cfg.title} \
      --appIcon=${lib.escapeShellArg trayIcon} \
      ${argsStr} "$@"
  '';

  # Une commande `teams-<nom>` par profil : session isolée + deep-link tenant.
  # NB : le --user-data-dir garde le nom "teams-for-linux-<nom>" pour ne pas
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
    userSettings.teams = {
      enable = lib.mkEnableOption "Microsoft Teams via teams-for-linux (wrapper Electron)";

      pkgs = lib.mkOption {
        type = lib.types.pkgs;
        default = config.userSettings.defaultPkgs;
        description = "Pkgs to use";
      };

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
          # WaylandWindowDecorations : rendu Wayland natif sous Sway (sinon flou
          # / XWayland). WebRTCPipeWireCapturer : partage d'écran via le portail
          # PipeWire — sans lui teams-for-linux avertit au démarrage que le
          # partage d'écran Wayland risque de ne pas fonctionner.
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
          # Désactive la fenêtre d'aperçu (« thumbnail ») de partage d'écran,
          # toujours-au-dessus, qui s'ouvre en grand et fait un effet miroir
          # quand on partage l'écran qu'on regarde.
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
          { bouygues.tenantId = "bf2ec9bc-d21e-420c-8acf-29441b9f4d45"; }
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
      # Icône officielle Teams (512px) dans le thème d'icônes utilisateur,
      # référencée par `icon = "teams"` dans les entrées de menu.
      ".local/share/icons/hicolor/512x512/apps/teams.png".source = ./teams.png;
      # config.json de l'instance principale.
      ".config/teams-for-linux/config.json".source = configFile;
    }
    # config.json de chaque instance dédiée (même --user-data-dir).
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
