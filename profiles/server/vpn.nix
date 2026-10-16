{ ... }:

let
  domain = import ./domain.nix;
in
{
  systemSettings = {
    # Appairage : `sudo wg-new-peer <nom> <adresse>`.
    vpn.wireguard = {
      enable = true;
      # "DNS only" côté Cloudflare : leur proxy ne relaie pas l'UDP.
      host = "vpn.${domain}";

      dns = [ ];

      allowedIPs = [ "10.8.0.0/24" ];

      # Retirer une entrée révoque l'appareil au prochain rebuild.
      peers = [
        {
          name = "xiaomi_17t";
          trusted = true;
          publicKey = "2XpsKYhyyKszaFd91V8cQ7yynz04RZ37S040S2OU5DY=";
          address = "10.8.0.2";
          presharedKeyKey = "wireguard/xiaomi_17t_preshared_key";
        }
        {
          name = "gram";
          trusted = true;
          publicKey = "/gV7axgKpUvtPD/oEnbgC4CFpvRULEMAmGVekD4B/zI=";
          address = "10.8.0.3";
          presharedKeyKey = "wireguard/gram_preshared_key";
        }
        {
          name = "windows_gram";
          trusted = true;
          publicKey = "9q/Vrdgd2Q+o+GWGi8GePNlbQM9lLJ9SNNKwVWHDsWs=";
          address = "10.8.0.4";
          presharedKeyKey = "wireguard/windows_gram_preshared_key";
        }
        {
          name = "oppo_a74";
          publicKey = "gSR1i2a2jxgn3yeszMLjFMe8n+fXOTrFPMuvy0gEhko=";
          address = "10.8.0.5";
          presharedKeyKey = "wireguard/oppo_a74_preshared_key";
        }
        {
          name = "xiaomi_9t";
          publicKey = "hcqtv8ay9e0DKE1qRxWc4+FW2JAiDkWYTbiMIjfPJCE=";
          address = "10.8.0.6";
          presharedKeyKey = "wireguard/xiaomi_9t_preshared_key";
        }
        {
          name = "xiaomi_14tpro";
          publicKey = "pJ7CyK5txL/l2lVqsJ7cD+VGa69WOPy7ixGH7DtIDH0=";
          address = "10.8.0.7";
          presharedKeyKey = "wireguard/xiaomi_14tpro_preshared_key";
        }
        {
          name = "lenovo_tab_p12";
          publicKey = "AyLyEp/YhPJaLNMwIfyZibWt6XymReCgVUXLLQ6JqXs=";
          address = "10.8.0.8";
          presharedKeyKey = "wireguard/lenovo_tab_p12_preshared_key";
        }
      ];

      # Précondition : un appareil appairé en tunnel complet (`AllowedIPs = 0.0.0.0/0`) perdrait internet ;
      # regénérer son profil ou remettre `true`.
      peerInternetAccess = false;

      peerLanAccess = [ ];
    };
  };
}
