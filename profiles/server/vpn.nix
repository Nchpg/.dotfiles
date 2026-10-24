{ ... }:

let
  domain = import ./domain.nix;
in
{
  systemSettings = {
    # Appairage : page VPN du dashboard (« Ajouter un appareil »), ou `sudo wg-new-peer <nom> <adresse>`.
    vpn.wireguard = {
      enable = true;
      # "DNS only" côté Cloudflare : leur proxy ne relaie pas l'UDP.
      host = "vpn.${domain}";

      dns = [ ];

      allowedIPs = [ "10.8.0.0/24" ];

      # Les appareils et leurs services réservés (dashboard, vaultwarden) : gérés depuis la page VPN du
      # dashboard. Retirer une entrée révoque l'appareil au prochain rebuild.
      peersFile = ./vpn-peers.json;

      # Précondition : un appareil appairé en tunnel complet (`AllowedIPs = 0.0.0.0/0`) perdrait internet ;
      # regénérer son profil ou remettre `true`.
      peerInternetAccess = false;

      peerLanAccess = [ ];
    };
  };
}
