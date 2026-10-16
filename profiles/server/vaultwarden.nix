{ config, ... }:

let
  domain = import ./domain.nix;
  wireguard = config.systemSettings.vpn.wireguard;

  mesAppareils = wireguard.trustedSources ++ [ wireguard.selfSource ];
in
{
  systemSettings = {
    # Précondition hors dépôt : un A `vault.vpn.nathanchampagne.com` vers 10.8.0.1 en "DNS only".
    vaultwarden = {
      enable = true;
      hostName = "vault.vpn.${domain}";

      allowedNetworks = mesAppareils;

      # Pour rouvrir les inscriptions, repasser à `true` le temps d'un rebuild.
      signups.enable = false;
    };
  };
}
