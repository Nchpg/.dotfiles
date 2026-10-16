{ ... }:

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
  };

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
