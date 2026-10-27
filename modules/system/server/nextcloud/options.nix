{
  config,
  lib,
  ...
}:

{
  options.systemSettings.nextcloud = {
    enable = lib.mkEnableOption "Nextcloud (PostgreSQL et Redis locaux)";

    hostName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "cloud.exemple.fr";
      description = ''
        Nom public servi par le tunnel, d'après lequel Nextcloud fabrique ses URL.
      '';
    };

    extraHostNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "cloud.vpn.exemple.fr" ];
      description = ''
        Noms supplémentaires de la même instance (alias du vhost et domaines de confiance).
      '';
    };

    mailFrom = lib.mkOption {
      type = lib.types.str;
      default = "cloud@${config.systemSettings.mail.domain}";
      defaultText = lib.literalExpression ''"cloud@''${systemSettings.mail.domain}"'';
      description = "Adresse d'expéditeur de Nextcloud (une adresse par service).";
    };

    adminUser = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      description = "Compte administrateur créé à la première initialisation.";
    };

    previews = {
      pregenerate = lib.mkEnableOption ''
        la fabrication des miniatures à l'avance, par previewgenerator
      '';

      interval = lib.mkOption {
        type = lib.types.str;
        default = "*:0/30";
        description = "Fréquence de la pré-génération, au format `OnCalendar` de systemd.";
      };
    };

    enforceTwoFactor = lib.mkEnableOption ''
      l'obligation d'un second facteur pour tous les comptes Nextcloud.

      Secours : sudo -u nextcloud nextcloud-occ twofactorauth:disable <utilisateur>
    '';

    publicSharing = {
      enable = lib.mkEnableOption ''
        les liens de partage publics pour un destinataire extérieur.

        Contourne le portail Authelia pour les chemins de `autheliaResources`
        sur le seul `hostName` ; le code de `files_sharing` devient joignable
        depuis internet
      '';

      linkExpireDays = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        example = 60;
        description = ''
          Durée de vie par défaut d'un nouveau lien, en jours (`null` : sans
          expiration). Désactiver `enable` laisse le réglage en base.
        '';
      };

      canonicalLinkHost = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Fabrique les liens de partage avec `hostName`, même créés via un
          `extraHostNames`. Ne couvre pas l'interface web : voir `canonicalLinkWebUi`.
        '';
      };

      canonicalLinkWebUi = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Fige l'hôte du lien de partage dans l'interface web en patchant `dist/*.js`.
          Le build échoue si le motif ne correspond plus après une mise à jour.
        '';
      };

      neutralNotFound = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Page d'erreur neutre quand un jeton de partage n'existe pas ou a expiré.
        '';
      };

      canonicalLinkPaths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        readOnly = true;
        default = [ "~^/ocs/v[12]\\.php/apps/files_sharing/" ];
        defaultText = lib.literalExpression "les points d'entrée OCS de l'application de partage";
        description = ''
          Chemins où `canonicalLinkHost` impose `HTTP_HOST`, en motifs de `map` nginx sur `$request_uri`.
        '';
      };

      rateLimit = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Limite le débit par adresse sur les chemins de partage.
          '';
        };

        rate = lib.mkOption {
          type = lib.types.str;
          default = "10r/s";
          description = ''
            Débit soutenu par adresse (format `limit_req_zone`).
          '';
        };

        burst = lib.mkOption {
          type = lib.types.ints.positive;
          default = 30;
          description = "Rafale tolérée, servie sans délai.";
        };

        previewRate = lib.mkOption {
          type = lib.types.str;
          default = "40r/s";
          description = ''
            Débit par adresse pour les vignettes de partage, zone distincte de `rate`.
          '';
        };

        previewBurst = lib.mkOption {
          type = lib.types.ints.positive;
          default = 80;
          description = "Rafale tolérée sur les vignettes.";
        };
      };

      autheliaResources = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        readOnly = true;
        default = [
          "^/s/"
          "^/index\\.php/s/"

          "^/public\\.php"

          # Pas de `^/apps/files_sharing/` général (shareFolder, accept, externalShares).
          "^/apps/files_sharing/(publicpreview|shareinfo)"
          "^/index\\.php/apps/files_sharing/(publicpreview|shareinfo)"

          # Pas `ajax/uploadImage` ni `background/*`.
          "^/apps/theming/(theme|image|manifest|favicon|icon|img)/"
          "^/index\\.php/apps/theming/(theme|image|manifest|favicon|icon|img)/"

          "^/csrftoken"
          "^/index\\.php/csrftoken"

          "^/core/(css|js|img|fonts|l10n|vendor)/"
          "^/apps/[^/]+/(css|js|img|fonts|l10n)/"
          "^/dist/"
          "^/favicon\\.ico$"
        ];
        defaultText = lib.literalExpression "les chemins qu'emprunte une page de partage public";
        description = ''
          Chemins exemptés du portail (regex `resources` d'Authelia). Ne doivent
          pas y venir : `/remote.php`, `/ocs`, `/login`, `/settings`, `/apps/files`.
        '';
      };
    };

    language = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "fr";
      description = ''
        Langue de l'interface (ISO à deux lettres) pour les nouveaux comptes.
      '';
    };

    locale = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "fr_FR";
      description = "Format des dates, nombres et premier jour de la semaine.";
    };

    forceLanguage = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Impose langue et format à tous les comptes.";
    };

    theming = {
      enable = lib.mkEnableOption ''
        un thème en aplats de couleur, sans image de fond, dérivé du schéma stylix actif
      '';

      primaryColor = lib.mkOption {
        type = lib.types.str;
        default = "#${config.lib.stylix.colors.base0D}";
        defaultText = lib.literalExpression "la couleur d'accent du schéma stylix";
        description = "Couleur des boutons, liens et éléments actifs.";
      };

      backgroundColor = lib.mkOption {
        type = lib.types.str;
        default = "#${config.lib.stylix.colors.base00}";
        defaultText = lib.literalExpression "la couleur de fond du schéma stylix";
        description = "Fond de l'interface, à la place de l'image livrée.";
      };

      name = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "Cloud familial";
        description = "Nom affiché à la place de « Nextcloud ». `null` conserve le défaut.";
      };

      customCss = lib.mkOption {
        type = lib.types.lines;
        default = "";
        example = "#contactsmenu { display: none !important; }";
        description = ''
          Feuille de style injectée dans toutes les pages (application `theming_customcss`).
        '';
      };

      lockUserTheming = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Empêche chaque compte de choisir ses couleurs.";
      };
    };

    enabledApps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "sharebymail" ];
      description = ''
        Applications à réactiver explicitement ; retirer une entrée de `disabledApps` ne rallume rien.
      '';
    };

    disabledApps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "dashboard" ];
      description = ''
        Applications livrées avec Nextcloud à désactiver, appliqué par `occ` après l'installation.
      '';
    };

    chunkSizeMiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 50;
      description = ''
        Taille maximale d'un morceau de téléversement, en Mio (Cloudflare refuse
        les corps de plus de 100 Mo : ne pas dépasser 90).
      '';
    };

    maxUploadSize = lib.mkOption {
      type = lib.types.str;
      default = "16G";
      description = ''
        Plafond de téléversement (`upload_max_filesize`, `post_max_size`, `client_max_body_size`).
      '';
    };
  };
}
