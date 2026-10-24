{ ... }:

let
  domain = import ./domain.nix;
in
{
  systemSettings = {
    # Précondition hors dépôt : un A `vault.vpn.nathanchampagne.com` vers 10.8.0.1 en "DNS only".
    vaultwarden = {
      enable = true;
      hostName = "vault.vpn.${domain}";

      # Accès : les appareils qui ont le service « vaultwarden » (page VPN du dashboard).

      # Pour rouvrir les inscriptions, repasser à `true` le temps d'un rebuild.
      signups.enable = false;
    };
  };
}
