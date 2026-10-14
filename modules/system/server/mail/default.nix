{
  config,
  lib,
  ...
}:

# Relais SMTP sortant, déclaré UNE fois et consommé par les services qui
# envoient du courrier (Authelia, Nextcloud). Sans ça, chacun recopie serveur,
# port, identifiant et expéditeur, et changer de relais veut dire les retrouver
# un par un — celui qu'on oublie se découvre le jour où un mail ne part pas.
#
# Un relais tiers reste nécessaire : envoyer en direct depuis une adresse
# résidentielle finit en indésirable, quand ce n'est pas en rejet.
let
  cfg = config.systemSettings.mail;

  # Authelia attend une URL dont le schéma décrit le mode de chiffrement.
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
      description = ''
        Port du relais. 465 pour du TLS implicite, 587 pour du STARTTLS. Le 465
        est accepté à peu près partout et ne dépend pas d'une négociation que le
        serveur pourrait refuser en silence.
      '';
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
      description = ''
        Adresse d'expéditeur, rarement à changer : beaucoup d'hébergeurs
        REFUSENT un expéditeur qui ne correspond pas au compte authentifié.
        Elle appartient au domaine et non au relais, donc elle survit à un
        changement d'hébergeur.
      '';
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
      description = ''
        Vrai pour du TLS implicite (465), faux pour une négociation STARTTLS.
        Dérivé du port, à référencer plutôt qu'à recalculer : chaque service le
        traduit dans son propre vocabulaire (`ssl`/`tls` pour Nextcloud,
        `force_tls`/`starttls` pour Vaultwarden, le schéma de `url` pour
        Authelia), et trois tests `port == 465` recopiés finiraient par
        diverger.
      '';
    };

    url = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = lib.optionalString cfg.enable "${scheme}://${cfg.host}:${toString cfg.port}";
      defaultText = lib.literalExpression "dérivée de host et port";
      description = ''
        URL du relais au format attendu par Authelia, dont le schéma porte le
        mode de chiffrement. Dérivée, à référencer plutôt qu'à reconstruire.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.host != "" && cfg.user != "";
        message = "systemSettings.mail : host et user sont requis dès que le relais est activé.";
      }
    ];

    # Groupe dédié plutôt qu'un propriétaire en dur : plusieurs services lisent
    # ce mot de passe, chacun sous son propre utilisateur, et s'ajoutent au
    # groupe depuis leur module — celui-ci n'a pas à connaître ses consommateurs.
    users.groups.smtp = { };

    sops.secrets.${cfg.passwordKey} = {
      group = "smtp";
      mode = "0440";
    };
  };
}
