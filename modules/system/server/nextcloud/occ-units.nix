{
  config,
  lib,
  pkgs-stable,
  ...
}:

# Unités qui appliquent par `occ` ce que `services.nextcloud.settings` ne sait
# pas porter : réglages d'APPLICATION rangés en base, état des applications,
# miniatures pré-générées.
let
  cfg = config.systemSettings.nextcloud;

  occ = lib.getExe config.services.nextcloud.occ;

  # Réglages communs aux unités qui appellent `occ`.
  #
  # Le `LoadCredential` n'est pas facultatif dès qu'un `secretFile` existe : le
  # wrapper nextcloud-occ vérifie `CREDENTIALS_DIRECTORY` et, s'il ne le trouve
  # pas, se relance par `systemd-run` — ce que l'utilisateur `nextcloud` n'a pas
  # le droit de faire. La commande échoue alors sur un « Access denied » sans
  # rapport apparent avec Nextcloud.
  occServiceConfig = {
    Type = "oneshot";
    User = "nextcloud";
    LoadCredential = lib.optional (
      config.services.nextcloud.secretFile != null
    ) "secret_file:${config.services.nextcloud.secretFile}";
  };

  # Une unité `occ` : oneshot sous l'utilisateur nextcloud, après
  # l'installation, et lancée au démarrage sauf mention contraire. Tout passe
  # par `occServiceConfig` et non par un bloc à part : c'est lui qui porte le
  # `LoadCredential` sans lequel le wrapper `occ` échoue sur un « Access
  # denied » qui ne nomme ni Nextcloud ni les credentials. La pré-génération
  # des miniatures s'en passait, et échouait donc à chaque passage du minuteur.
  mkOccUnit =
    {
      description,
      script,
      wantedBy ? [ "multi-user.target" ],
      path ? [ ],
      serviceConfig ? { },
    }:
    {
      inherit
        description
        script
        wantedBy
        path
        ;
      after = [ "nextcloud-setup.service" ];
      requires = [ "nextcloud-setup.service" ];
      serviceConfig = occServiceConfig // serviceConfig;
    };
in
{
  config = lib.mkIf cfg.enable {
    # La tâche de fond fabrique aussi des aperçus. Elle tourne en PHP CLI et non
    # derrière fpm, donc le PATH de l'unité lui suffit.
    systemd.services.nextcloud-cron.path = [ pkgs-stable.ffmpeg-headless ];

    # `preview:pre-generate` ne traite que ce qui a été ajouté depuis le dernier
    # passage, il est donc rapide en régime établi. Le RATTRAPAGE initial se
    # lance à la main, une seule fois :
    #
    #   sudo nextcloud-occ preview:generate-all
    #
    # En ROOT et non en `sudo -u nextcloud` : le wrapper se relance par
    # `systemd-run` pour charger les credentials, ce que l'utilisateur
    # `nextcloud` n'a pas le droit de demander. Même cause que le
    # `LoadCredential` d'`occServiceConfig`.
    #
    # Sur une bibliothèque déjà remplie, comptez des heures : à lancer dans un
    # tmux, pas dans une session SSH qu'une coupure interromprait.
    systemd.services.nextcloud-preview-pregenerate = lib.mkIf cfg.previews.pregenerate (mkOccUnit {
      description = "Fabrique à l'avance les miniatures Nextcloud";
      # Déclenchée par son minuteur, pas au démarrage.
      wantedBy = [ ];
      path = [ pkgs-stable.ffmpeg-headless ];
      serviceConfig = {
        # Longue et sans urgence : elle ne doit pas disputer le processeur aux
        # requêtes des utilisateurs.
        Nice = 19;
        IOSchedulingClass = "idle";
      };
      script = "${occ} preview:pre-generate";
    });

    systemd.timers.nextcloud-preview-pregenerate = lib.mkIf cfg.previews.pregenerate {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.previews.interval;
        Persistent = true;
      };
    };

    # Un seul appel à occ pour toute la liste, et non un par application : chacun
    # démarre un interpréteur PHP complet et charge Nextcloud, ce qui se
    # compterait en dizaines de secondes à chaque activation.
    #
    # `|| true` volontaire : une application déjà désactivée, ou protégée par la
    # liste `alwaysEnabled` de Nextcloud, fait sortir occ en erreur, et ce n'est
    # pas une raison d'interrompre l'activation du système. Il ne masque plus
    # l'échec du wrapper lui-même, réglé par le LoadCredential.
    systemd.services.nextcloud-apps =
      lib.mkIf (cfg.disabledApps != [ ] || cfg.enabledApps != [ ])
        (mkOccUnit {
          description = "Applique l'état des applications Nextcloud";
          script =
            lib.optionalString (cfg.enabledApps != [ ]) ''
              ${occ} app:enable ${lib.concatStringsSep " " cfg.enabledApps} || true
            ''
            + lib.optionalString (cfg.disabledApps != [ ]) ''
              ${occ} app:disable ${lib.concatStringsSep " " cfg.disabledApps} || true
            '';
        });

    # Réglages de partage. Par `occ` et non par `settings` : ce sont des valeurs
    # d'APPLICATION, rangées dans `oc_appconfig` sous l'application `core`, et un
    # `settings` les écrirait dans config.php où personne ne les lit. Même
    # distinction que pour le thème juste en dessous — vérifier la source plutôt
    # que le nom.
    systemd.services.nextcloud-sharing = lib.mkIf cfg.publicSharing.enable (mkOccUnit {
      description = "Applique les réglages de partage public Nextcloud";
      script =
        let
          set = key: value: "${occ} config:app:set core ${key} --value ${lib.escapeShellArg value}";
        in
        lib.concatStringsSep "\n" (
          if cfg.publicSharing.linkExpireDays != null then
            [
              (set "shareapi_default_expire_date" "yes")
              (set "shareapi_expire_after_n_days" (toString cfg.publicSharing.linkExpireDays))
              # Un DÉFAUT, pas un plafond : sans cette ligne à `no`, la date
              # posée au-dessus deviendrait indépassable et un partage qui doit
              # durer obligerait à rebuild.
              (set "shareapi_enforce_expire_date" "no")
            ]
          else
            # Remise à zéro explicite, le mécanisme étant à sens unique : cesser
            # d'écrire une valeur d'appconfig ne l'efface pas, et une expiration
            # posée puis retirée du profil resterait en place indéfiniment.
            [ (set "shareapi_default_expire_date" "no") ]
        );
    });

    # Le thème passe par `occ` et non par `settings` : ce sont des réglages
    # d'APPLICATION, contrairement à `twofactor_enforced` qui, malgré son nom,
    # était une valeur système. Vérifier la source plutôt que le nom, à chaque
    # fois.
    #
    # La feuille de style est appliquée INDÉPENDAMMENT des couleurs. Masquer des
    # éléments d'interface et choisir une palette sont deux sujets sans rapport,
    # et les avoir couplés obligeait à subir un thème pour garder des masquages —
    # ou l'inverse.
    systemd.services.nextcloud-theming =
      lib.mkIf (cfg.theming.enable || cfg.theming.customCss != "")
        (mkOccUnit {
          description = "Applique le thème Nextcloud";
          script =
            let
              set = key: value: "${occ} theming:config ${key} ${lib.escapeShellArg value}";

              # Les valeurs de thème vivent dans la BASE de Nextcloud, pas dans la
              # configuration : cesser de les écrire ne les efface pas. Sans cette
              # remise à zéro, désactiver `theming.enable` laissait l'ancienne
              # palette en place indéfiniment — mécanisme à SENS UNIQUE, exactement
              # comme `disabledApps`, et pour la même raison.
              reset = key: "${occ} theming:config ${key} --reset";
              themedKeys = [
                "primary_color"
                "background_color"
                "background"
                "disable-user-theming"
                "name"
              ];
            in
            lib.concatStringsSep "\n" (
              lib.optionals (!cfg.theming.enable) (map reset themedKeys)
              ++ lib.optionals cfg.theming.enable (
                [
                  (set "primary_color" cfg.theming.primaryColor)
                  (set "background_color" cfg.theming.backgroundColor)
                  # `backgroundColor` est la valeur MAGIQUE que la commande
                  # reconnaît pour effacer l'image de fond et laisser l'aplat. À
                  # ne pas confondre avec la constante interne
                  # `BACKGROUND_COLOR = 'color'`, qui gouverne le choix par
                  # utilisateur : passer `color` ici fait échouer la commande sur
                  # « The image file needs to be provided as an absolute path ».
                  (set "background" "backgroundColor")
                  (set "disable-user-theming" (if cfg.theming.lockUserTheming then "yes" else "no"))
                ]
                ++ lib.optional (cfg.theming.name != null) (set "name" cfg.theming.name)
              )
              ++ lib.optionals (cfg.theming.customCss != "") [
                "${occ} config:app:set theming_customcss customcss --value ${lib.escapeShellArg cfg.theming.customCss}"
                # Le cachebuster VERSIONNE l'URL de la feuille : sans lui, les
                # navigateurs resservent celle qu'ils ont en cache. Dérivé du
                # contenu, il ne bouge que quand la feuille change.
                "${occ} config:app:set theming_customcss cachebuster --value ${
                  builtins.substring 0 8 (builtins.hashString "sha256" cfg.theming.customCss)
                }"
              ]
            );
        });
  };
}
