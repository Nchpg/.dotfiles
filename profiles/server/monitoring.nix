{ ... }:

let
  domain = import ./domain.nix;
in
{
  systemSettings = {
    monitoring = {
      enable = true;

      grafana = {
        hostName = "metrics.${domain}";
        public = true;
      };

      disks.enable = true;

      # À régler côté healthchecks : période 15 min, grâce 10 min, sinon le redémarrage nocturne de gitops fait sonner.
      deadManSwitch.enable = true;

      apps.enable = true;

      logs.enable = true;

      # Déclarer la clé d'abord : elle fait apparaître la règle de création dans le .sops.yaml du dépôt privé.
      apps.nextcloudTokenKey = "nextcloud/serverinfo_token";
    };

    proxy.sites."metrics.${domain}" = {
      # `public` reste faux : la route du tunnel est posée par `grafana.public`.
      lanShortcut = true;

      # Les sondes partent de think et ne traversent pas le tunnel : seul le dead man's switch voit une panne de cloudflared.
      probes.grafana.module = "http_authelia";
    };

    authelia.rules = [
      # Grafana donne Admin à quiconque franchit le portail : `subject` écarte les comptes familiaux
      # (nom du fichier d'utilisateurs Authelia). Pas de `networks`.
      {
        domain = "metrics.${domain}";
        policy = "two_factor";
        subject = [ "user:nathan" ];
      }
    ];
  };
}
