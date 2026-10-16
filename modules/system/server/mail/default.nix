{
  config,
  lib,
  ...
}:

let
  cfg = config.systemSettings.mail;

  scheme =
    if cfg.implicitTls then
      "submissions"
    else if cfg.port == 587 then
      "submission"
    else
      "smtp";
in
{
  options.systemSettings.mail = {
    enable = lib.mkEnableOption "relais SMTP sortant partagé";

    host = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "smtp.exemple.fr";
      description = "Serveur SMTP du relais.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 465;
      description = "Port du relais : 465 pour du TLS implicite, 587 pour du STARTTLS.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "nextcloud@exemple.fr";
      description = "Identifiant d'authentification, en général l'adresse de la boîte.";
    };

    from = lib.mkOption {
      type = lib.types.str;
      default = cfg.user;
      defaultText = lib.literalExpression "systemSettings.mail.user";
      description = "Adresse d'expéditeur.";
    };

    passwordKey = lib.mkOption {
      type = lib.types.str;
      default = "smtp/password";
      description = "Clé du mot de passe dans le dépôt de secrets.";
    };

    implicitTls = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      default = cfg.port == 465;
      defaultText = lib.literalExpression "port == 465";
      description = "Vrai pour du TLS implicite (465), faux pour du STARTTLS. Dérivé du port.";
    };

    url = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = lib.optionalString cfg.enable "${scheme}://${cfg.host}:${toString cfg.port}";
      defaultText = lib.literalExpression "dérivée de host et port";
      description = "URL du relais au format Authelia (le schéma porte le mode de chiffrement).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.host != "" && cfg.user != "";
        message = "systemSettings.mail : host et user sont requis dès que le relais est activé.";
      }
    ];

    users.groups.smtp = { };

    sops.secrets.${cfg.passwordKey} = {
      group = "smtp";
      mode = "0440";
    };
  };
}
