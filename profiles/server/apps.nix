{ config, ... }:

# Applications web servies depuis des images de conteneurs.
let
  domain = import ./domain.nix;
  wireguard = config.systemSettings.vpn.wireguard;

  mesAppareils = wireguard.trustedSources ++ [ wireguard.selfSource ];
in
{
  systemSettings = {
    # `hostPort` figés pour ne pas renuméroter les autres ; 8085 reste libre pour `stage`.

    apps."portfolio" = {
      hostPort = 8083;

      # Seule sonde qui passe par l'edge Cloudflare (l'apex n'a pas de réécriture dnsmasq) : pas d'override pour ce nom.
      probe = { };

      inherit domain;

      containers.web = {
        image = "ghcr.io/nchpg/portfolio@sha256:1bf19ec8da2104d05b862f71d1e8578376ce56b2715957bb3e4a1ad7b794e678";
        port = 3000;

        # Pas un secret : servi en clair dans un <meta>.
        environment.GOOGLE_SITE_VERIFICATION = "TfARlD-WI-dO71XO0G7bcmm5VvA_ra5idC-HK-Nd9qM";
      };
    };

    apps."rlkart" = {
      hostPort = 8084;

      probe = { };

      domain = "rlkart.${domain}";
      entrypoint = "frontend";

      containers = {
        frontend = {
          image = "ghcr.io/nchpg/rlkart-frontend@sha256:5f7b09c3452b9b1502e2b8c108f48bad28d31ef577b190b691624b1b7f282cb2";
          port = 80;

          dependsOn = [ "backend" ];

          # nginx officiel : root puis abandon des privilèges.
          capabilities = [
            "CHOWN"
            "SETUID"
            "SETGID"
          ];
        };

        backend = {
          image = "ghcr.io/nchpg/rlkart-backend@sha256:939e1f49e41a5b1e3a2fdf298a4d4f1ccd892ae6b92da9f9805e5b6937d7429d";
          port = 8000;
        };
      };

      rateLimit = {
        enable = true;
        paths = [
          "/generate"
          "/simulate"
        ];
      };
    };

    apps."mnist" = {
      hostPort = 8081;

      probe = { };

      domain = "mnist.${domain}";

      containers.web = {
        image = "ghcr.io/nchpg/mnist-cnn-cpp@sha256:64d15f30c87fdcb4774aed39f2bb99cedda84fd50c45f559b82ce6f31e9b8dc1";

        port = 8080;

        user = "1000:1000";

        memory = "256m";
      };

      rateLimit = {
        enable = true;
        paths = [ "/predict" ];
      };
    };

    # Précondition hors dépôt : `cloudflared tunnel route dns <tunnel> trafficvision.nathanchampagne.com`.
    # Attribut `traffic` et non `trafficvision` : il nomme le pont `br-<nom>` (15 caractères max).
    apps."traffic" = {
      hostPort = 8086;
      domain = "trafficvision.${domain}";

      containers.web = {
        image = "ghcr.io/nchpg/yolo-detection@sha256:7bce55e4c5397d3540dc38d2526bfe59dece26426a07b86004214c4cb6f8a2a0";

        port = 8080;

        memory = "128m";
      };
    };

    # Précondition hors dépôt : `cloudflared tunnel route dns <tunnel> iseg2017.nathanchampagne.com`.
    apps."iseg2017" = {
      hostPort = 8080;
      domain = "iseg2017.${domain}";

      containers.web = {
        image = "ghcr.io/nchpg/iseg-2017@sha256:e0b54b079669ad0bb7cad2bf9d64baed066de45689ca618c49f36612e3f03aba";

        # `iseg-2017` en minuscules : ghcr.io refuse les majuscules.
        port = 8080;

        memory = "128m";
      };
    };

    apps."myetf" = {
      hostPort = 8082;

      probe = { };

      domain = "etf.vpn.${domain}";
      public = false;
      allowedNetworks = mesAppareils;

      internetAccess = true;

      containers.web = {
        image = "ghcr.io/nchpg/myetf@sha256:4fbfd4c90f69ed23c30644b24a7a920696839453f444a13eb5fa528f18b75115";
        port = 3000;

        login = {
          username = "Nchpg";
          passwordKey = "stage/ghcr_token";
        };

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
