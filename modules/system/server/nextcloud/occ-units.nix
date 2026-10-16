{
  config,
  lib,
  pkgs-stable,
  ...
}:

let
  cfg = config.systemSettings.nextcloud;

  occ = lib.getExe config.services.nextcloud.occ;

  # Sans CREDENTIALS_DIRECTORY, le wrapper occ passe par `systemd-run`, interdit à `nextcloud`.
  occServiceConfig = {
    Type = "oneshot";
    User = "nextcloud";
    LoadCredential = lib.optional (
      config.services.nextcloud.secretFile != null
    ) "secret_file:${config.services.nextcloud.secretFile}";
  };

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
    systemd.services.nextcloud-cron.path = [ pkgs-stable.ffmpeg-headless ];

    # `preview:pre-generate` ne traite que les ajouts ; rattrapage initial : `sudo nextcloud-occ preview:generate-all`.
    systemd.services.nextcloud-preview-pregenerate = lib.mkIf cfg.previews.pregenerate (mkOccUnit {
      description = "Fabrique à l'avance les miniatures Nextcloud";
      wantedBy = [ ];
      path = [ pkgs-stable.ffmpeg-headless ];
      serviceConfig = {
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

    # `|| true` : une application déjà désactivée ou `alwaysEnabled` fait sortir occ en erreur.
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
              (set "shareapi_enforce_expire_date" "no")
            ]
          else
            # Retirer l'écriture n'efface pas la valeur en base.
            [ (set "shareapi_default_expire_date" "no") ]
        );
    });

    systemd.services.nextcloud-theming =
      lib.mkIf (cfg.theming.enable || cfg.theming.customCss != "")
        (mkOccUnit {
          description = "Applique le thème Nextcloud";
          script =
            let
              set = key: value: "${occ} theming:config ${key} ${lib.escapeShellArg value}";

              # Les valeurs vivent en base : sans remise à zéro l'ancienne palette resterait.
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
                  # "backgroundColor" est la valeur magique qui efface l'image de fond.
                  (set "background" "backgroundColor")
                  (set "disable-user-theming" (if cfg.theming.lockUserTheming then "yes" else "no"))
                ]
                ++ lib.optional (cfg.theming.name != null) (set "name" cfg.theming.name)
              )
              ++ lib.optionals (cfg.theming.customCss != "") [
                "${occ} config:app:set theming_customcss customcss --value ${lib.escapeShellArg cfg.theming.customCss}"
                "${occ} config:app:set theming_customcss cachebuster --value ${
                  builtins.substring 0 8 (builtins.hashString "sha256" cfg.theming.customCss)
                }"
              ]
            );
        });
  };
}
