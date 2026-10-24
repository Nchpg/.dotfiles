{ config, lib, ... }:

# Dashboard d'administration sur admin.vpn.<domaine> : mes appareils, puis Authelia en 2FA.
{
  systemSettings.admin = {
    enable = true;
    # Les appareils qui ont le service « admin » (vpn-peers.json, page VPN), rangés par nom.
    devices = lib.sort lib.lessThan (
      map (p: p.name) (
        lib.filter (p: lib.elem "admin" (p.services or [ ])) config.systemSettings.vpn.wireguard.peers
      )
    );
  };
}
