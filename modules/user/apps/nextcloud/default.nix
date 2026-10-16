{
  config,
  lib,
  myLib,
  themes,
  ...
}:

let
  cfg = config.userSettings.apps.nextcloud;

  scheme = themes.parseScheme config.userSettings.stylix.theme;

  # Style.qml patché : l'en-tête de compte prend la couleur de marque du serveur sinon.
  nextcloudClient = cfg.pkgs.nextcloud-client.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace theme/Style/Style.qml \
        --replace-fail \
          'readonly property color ncBlue: Theme.wizardHeaderBackgroundColor' \
          'readonly property color ncBlue: "#${scheme.base01}"' \
        --replace-fail \
          'readonly property color ncHeaderTextColor: Theme.wizardHeaderTitleColor' \
          'readonly property color ncHeaderTextColor: "#${scheme.base05}"' \
        --replace-fail \
          'readonly property color currentUserHeaderColor: UserModel.currentUser ? UserModel.currentUser.headerColor : ncBlue' \
          'readonly property color currentUserHeaderColor: ncBlue' \
        --replace-fail \
          'readonly property color currentUserHeaderTextColor: UserModel.currentUser ? UserModel.currentUser.headerTextColor : ncHeaderTextColor' \
          'readonly property color currentUserHeaderTextColor: ncHeaderTextColor'
    '';
  });

  # Retire les couleurs de marque du serveur de nextcloud.cfg à chaque démarrage.
  stripBrandingColors = cfg.pkgs.writeShellScript "nextcloud-strip-branding-colors" ''
    cfgfile="$HOME/.config/Nextcloud/nextcloud.cfg"
    if [ -f "$cfgfile" ]; then
      ${cfg.pkgs.gnused}/bin/sed -i -E '/^[0-9]+\\server(Color|TextColor)=/d' "$cfgfile"
    fi
  '';
in
{
  options.userSettings.apps.nextcloud = {
    enable = lib.mkEnableOption "client de synchronisation Nextcloud";

    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ nextcloudClient ];

    services.nextcloud-client = {
      enable = true;
      package = nextcloudClient;

      startInBackground = true;
    };

    # Sans QPalette stylix, l'UI QML reste en texte noir sur fond sombre : gtk3 + Fusion.
    systemd.user.services.nextcloud-client.Service = {
      Environment = [
        "QT_QPA_PLATFORMTHEME=gtk3"
        "QT_QUICK_CONTROLS_STYLE=Fusion"
      ];
      ExecStartPre = "${stripBrandingColors}";
    };
  };
}
