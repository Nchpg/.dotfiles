{ config, ... }:

{
  # Sauvegarde chiffrée de GarminMap (restic) vers Backblaze B2, région Europe : parcours, jetons Garmin,
  # réglages. Les tuiles se refont, elles ne partent pas. Procédure et restauration : deploy/README.md du
  # dépôt garminmap. Le mot de passe restic a aussi une copie hors de think : sans lui, la sauvegarde est
  # illisible.
  sops.secrets."map/restic-password" = { };
  sops.secrets."map/backup" = { }; # AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY : clé B2 limitée au bucket

  services.restic.backups.garminmap = {
    initialize = true;
    repository = "s3:https://s3.eu-central-003.backblazeb2.com/garminmap-sauvegarde";
    passwordFile = config.sops.secrets."map/restic-password".path;
    environmentFile = config.sops.secrets."map/backup".path;
    paths = [
      "/var/lib/apps/map/web/data"
      "/var/lib/apps/map/vault/data" # coffres Garmin, chiffrés : inutiles sans les tickets des appareils
    ];
    exclude = [ "/var/lib/apps/map/web/data/tiles" ];
    # Toutes les heures : plus souvent, les lectures de restic dépasseraient le quota gratuit quotidien de B2.
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
      RandomizedDelaySec = "5m";
    };
    pruneOpts = [
      "--keep-last 48"
      "--keep-daily 30"
      "--keep-monthly 6"
    ];
  };

  # Alerte Discord si une sauvegarde échoue.
  systemSettings.notify.discord.units = [ "restic-backups-garminmap" ];
}
