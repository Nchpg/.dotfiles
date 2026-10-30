{ ... }:

# Visionneuse Postgres sur pg.vpn.<domaine> : les appareils qui ont le service « pgweb »
# (vpn-peers.json, page VPN), puis Authelia en 2FA. En lecture seule, par les droits du rôle.
{
  systemSettings.pgweb.enable = true;
}
