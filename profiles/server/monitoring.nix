{ ... }:

let
  domain = import ./domain.nix;
in
{
  systemSettings = {
    monitoring = {
      enable = true;

      # Comme le dashboard : par le VPN (appareils qui ont le service « grafana », page VPN), puis
      # Authelia en 2FA. Le joker DNS *.vpn pointe déjà sur think dans le tunnel.
      grafana.hostName = "metrics.vpn.${domain}";

      disks.enable = true;

      # À régler côté healthchecks : période 15 min, grâce 10 min, sinon un redémarrage fait sonner.
      deadManSwitch.enable = true;

      apps.enable = true;

      logs.enable = true;

      # Déclarer la clé d'abord : elle fait apparaître la règle de création dans le .sops.yaml du dépôt privé.
      apps.nextcloudTokenKey = "nextcloud/serverinfo_token";
    };

    proxy.sites."metrics.vpn.${domain}".probes.grafana.module = "http_authelia";

    authelia.rules = [
      # Grafana donne Admin à quiconque franchit le portail : `subject` écarte les comptes familiaux
      # (nom du fichier d'utilisateurs Authelia). Pas de `networks`.
      {
        domain = "metrics.vpn.${domain}";
        policy = "two_factor";
        subject = [ "user:nathan" ];
      }
    ];
  };
}
