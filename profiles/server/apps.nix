{ config, ... }:

# Applications web servies depuis des images de conteneurs (cf. docs/apps.md).
# Par défaut, une app est publique sur `<nom>.<domaine>` et sondée sur `/`. Son image
# `<image>:<branche>` (sous ghcr.io/nchpg) est épinglée par apps.lock.json, port exposé compris.
let
  # Noms de vpn.wireguard.peers ; les téléphones de la famille n'en font pas partie.
  mesAppareils = [
    "gram"
    "windows_gram"
    "xiaomi_17t"
  ];
in
{
  systemSettings.appImages = {
    lockFile = ./apps.lock.json;
    registry = "ghcr.io/nchpg";

    # Packages privés (myetf, stage) ; un PAT `read:packages` sans expiration.
    login = {
      username = "Nchpg";
      passwordKey = "ghcr/token";
    };

    # think repère une nouvelle image en une minute et la fait épingler (jeton `github/dispatch_token`).
    watch.enable = true;

    # Un message Discord par site mis à jour.
    announce = true;
  };

  sops.secrets."stage/gemini_env".restartUnits = [ "podman-stage-web.service" ];

  # Créé avant le conteneur et à son nom : sans CAP_CHOWN, il ne pourrait pas écrire dans un
  # répertoire que podman aurait créé en root. 0700 : le groupe `users` n'a rien à y lire.
  systemd.tmpfiles.rules = [
    "d /var/lib/stage 0700 1000 100 -"
    "d /var/lib/stage/pdfs 0700 1000 100 -"
    "d /var/lib/stage/logos 0700 1000 100 -"
  ];

  systemSettings.apps = {
    portfolio = {
      subdomain = "@";
      container.image = "portfolio:main";
    };

    rlkart = {
      entrypoint = "frontend";

      containers = {
        frontend = {
          image = "rlkart-frontend:main";
          dependsOn = [ "backend" ];

          # Pour l'ancienne image (nginx officiel, root). À retirer une fois épinglée
          # celle en nginx-unprivileged (8080, sans root).
          capabilities = [
            "CHOWN"
            "SETUID"
            "SETGID"
          ];
        };

        backend.image = "rlkart-backend:main";
      };

      rateLimit = {
        enable = true;
        paths = [
          "/generate"
          "/simulate"
        ];
      };
    };

    mnist = {
      container = {
        image = "mnist-cnn-cpp:main";
        # Pour l'ancienne image, sans utilisateur déclaré. À retirer une fois épinglée
        # celle qui fait `USER app`.
        user = "1000:1000";
        memory = "256m";
      };

      rateLimit = {
        enable = true;
        paths = [ "/predict" ];
      };
    };

    # Nom court : il nomme le pont `br-<nom>` (15 caractères max).
    traffic = {
      subdomain = "trafficvision";
      container = {
        image = "yolo-detection:main";
        memory = "128m";
      };
    };

    iseg2017.container = {
      image = "iseg-2017:main";
      memory = "128m";
    };

    # Suivi de candidatures (dépôt privé Nchpg/stage, package ghcr privé).
    stage = {
      expose = "vpn";
      devices = mesAppareils;

      # API Gemini (mise en forme des annonces). Le LAN reste fermé au conteneur.
      internetAccess = true;

      # La sonde lit le fichier : une app vivante dont le montage a disparu n'est pas disponible.
      probe.path = "/api/sante";

      container = {
        image = "stage:main";

        # nchpg:users, pour que le JSON déposé sur le host se lise sans sudo.
        user = "1000:100";

        # Next au repos tient dans une centaine de Mo ; la marge couvre l'export d'une archive.
        memory = "512m";

        # Sur le host et pas dans un volume podman : `candidatures.json` se lit et se copie directement.
        volumes = [
          {
            source = "/var/lib/stage";
            target = "/data";
            readOnly = false;
          }
        ];

        # Ligne complète `GEMINI_API_KEY=…` : podman lit un fichier d'environnement tel quel.
        environmentFiles = [ config.sops.secrets."stage/gemini_env".path ];

        # 127.0.0.1 et pas localhost : le wget de busybox essaie ::1 d'abord et le serveur
        # n'écoute qu'en IPv4.
        healthcheck.command = "wget -qO- http://127.0.0.1:3000/api/sante > /dev/null || exit 1";
      };
    };

    myetf = {
      expose = "vpn";
      devices = mesAppareils;
      subdomain = "etf";

      internetAccess = true;

      container = {
        image = "myetf:main";

        # À sauvegarder : seule copie des portefeuilles hors de gram.
        volumes = [
          {
            source = "myetf-data";
            target = "/app/data";
            readOnly = false;
          }
        ];
      };
    };
  };
}
