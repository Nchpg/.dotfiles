{ ... }:

let
  domain = import ./domain.nix;
in
{
  systemSettings = {
    nextcloud = {
      enable = true;
      hostName = "cloud.${domain}";

      # Chemin réservé aux clients de synchro (qui ne suivent pas une redirection d'authentification),
      # résolu vers 10.8.0.1 : les clients ne routent que 10.8.0.0/24.
      extraHostNames = [ "cloud.vpn.${domain}" ];

      # Le module injecte un `bypass` Authelia limité aux pages de partage. Pas de mot de passe imposé
      # (jeton de 15 caractères, pas d'énumération) : `password_policy` vaudrait aussi pour les comptes.
      publicSharing = {
        enable = true;

        # Sinon un partage sort en `https://cloud.vpn.…/s/<jeton>`, lien mort pour le destinataire.
        canonicalLinkHost = true;

        # Patche le bundle Nextcloud : une mise à jour qui le change fait échouer le rebuild.
        canonicalLinkWebUi = true;

        linkExpireDays = 60;
      };

      previews.pregenerate = true;

      language = "fr";
      locale = "fr_FR";

      # Authelia ne garde que le chemin public : le chemin interne n'est protégé que par mot de passe.
      enforceTwoFactor = true;

      theming = {
        # `base0D` (défaut du module) est terne sur l'interface claire.
        primaryColor = "#8ec07c";

        backgroundColor = "#83a598";

        # `name` reste nul : l'émetteur des URI TOTP vaut « Nextcloud » (icône des applications d'authentification).
        enable = true;

        # Sélecteurs sujets à changer à une mise à jour majeure (la règle cesserait de s'appliquer sans rien casser).
        customCss = builtins.readFile ./nextcloud.css;
      };

      # Restent : files, dav, files_sharing, photos, viewer, files_versions, files_trashbin.
      # Les apps de `alwaysEnabled` ne peuvent pas être désactivées.

      # Sorti de `disabledApps` pour le relais SMTP : il faut rallumer explicitement.
      enabledApps = [ "sharebymail" ];

      disabledApps = [
        "firstrunwizard"
        "nextcloud_announcements"
        "survey_client"
        "support"
        "updatenotification"
        "dashboard"
        "weather_status"
        "recommendations"
        "privacy"
        "related_resources"
        "files_reminders"
        # Seul `federation` peut partir : les autres sont dans `alwaysEnabled`.
        "federation"
        "contactsinteraction"
        "files_downloadlimit"
        "circles"
        "text"
        "files_external"
        "user_ldap"
        "admin_audit"
        "encryption"
        "app_api"
        "webhook_listeners"
        "suspicious_login"
        "comments"
        "user_status"
        "twofactor_nextcloud_notification"
        "activity"
      ];
    };
  };
}
