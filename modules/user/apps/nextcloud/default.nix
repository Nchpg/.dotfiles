{
  config,
  lib,
  myLib,
  themes,
  ...
}:

# Client de synchronisation Nextcloud. Gaté par profil, comme les autres
# applications : root/guest n'ont rien à synchroniser.
#
# Par le module home-manager plutôt qu'un simple paquet : il pose une unité
# utilisateur accrochée à `graphical-session.target`, donc le client démarre
# avec la session et s'arrête avec elle, au lieu de dépendre d'un fichier
# autostart que rien ne relit.
let
  cfg = config.userSettings.apps.nextcloud;

  # theme.userSettings.stylix.theme a toujours une valeur (défaut = thème
  # système), même sans stylix actif sur ce profil — même lecture que
  # modules/user/shell/fish pour les mêmes raisons.
  scheme = themes.parseScheme config.userSettings.stylix.theme;

  # L'en-tête de compte (avatar/nom) est peinte en dur par
  # theme/Style/Style.qml avec la couleur de marque du serveur
  # (UserModel.currentUser.headerColor), sans lien avec la QPalette système
  # ni un quelconque réglage client — ignore donc QT_QPA_PLATFORMTHEME.
  # Aucun réglage exposé côté client pour la désactiver. On patche la source
  # pour retomber inconditionnellement sur ncBlue/ncHeaderTextColor, et on
  # redéfinit ces deux constantes sur base01/base05 du scheme actif (au lieu
  # du bleu Nextcloud par défaut) : base01 est la teinte "status bar" de la
  # spec base16, cohérente par construction avec le reste de l'UI theming
  # via stylix. Ne touche qu'au binaire du client, jamais au serveur.
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

  # Le client persiste dans nextcloud.cfg les couleurs de marque du serveur
  # (0\serverColor, 0\serverTextColor), et les rejoue en dur sur certains
  # éléments (en-tête de compte, barre "Sync now"...) au lieu de suivre la
  # QPalette système. Résultat : ces éléments restent verts/clairs pendant
  # que le reste de l'UI (QT_QPA_PLATFORMTHEME=gtk3 plus bas) passe sombre —
  # incohérence visuelle. Le serveur les réécrit à chaque connexion de
  # compte, donc on les retire avant chaque démarrage plutôt qu'une fois.
  # N'affecte que le rendu local : la théorie web du serveur reste intacte.
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
    # Le module home-manager ne pose QUE l'unité systemd, sans ajouter le paquet
    # au profil : ni la commande `nextcloud`, ni son entrée `.desktop`, donc rien
    # dans le lanceur. En quittant depuis l'icône, on se retrouve sans aucun
    # moyen évident de rouvrir l'application — le service ne redémarre pas, une
    # sortie propre n'étant pas un échec.
    home.packages = [ nextcloudClient ];

    services.nextcloud-client = {
      enable = true;
      package = nextcloudClient;

      # Démarrage réduit dans la zone de notification, sinon la fenêtre du
      # client s'ouvre à chaque ouverture de session. Suppose une zone de
      # notification dans la barre — waybar en a une (cf. son module `tray`),
      # sans quoi le client tournerait sans aucun moyen de l'afficher.
      startInBackground = true;
    };

    # Le target stylix `qt` (modules/user/stylix) route les apps Qt vers
    # qt5ct/qt6ct avec `custom_palette = true`, mais n'écrit jamais de
    # véritable palette : il ne configure que Kvantum, qui ne sait peindre
    # que le chrome des QWidget. L'UI du client (activité, recherche) est en
    # QML/QQC2, qui lit directement la QPalette Qt — restée au défaut clair,
    # texte noir compris. Nextcloud détecte quand même le mode sombre système
    # et peint son propre fond foncé, d'où le texte noir sur fond sombre.
    # Basculer sur le thème de plateforme gtk3 fait lire à Qt la vraie
    # palette (claire ou sombre) du thème GTK actif à la place, fond et
    # texte cohérents. Fusion garde le rendu QQC2 fidèle à cette palette.
    systemd.user.services.nextcloud-client.Service = {
      Environment = [
        "QT_QPA_PLATFORMTHEME=gtk3"
        "QT_QUICK_CONTROLS_STYLE=Fusion"
      ];
      ExecStartPre = "${stripBrandingColors}";
    };
  };
}
