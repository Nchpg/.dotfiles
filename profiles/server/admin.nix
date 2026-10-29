{ ... }:

# Dashboard d'administration sur admin.vpn.<domaine> : les appareils qui ont le service « admin »
# (vpn-peers.json, page VPN), puis Authelia en 2FA. Les mises à jour lues par Gemini (clé gratuite
# de Google AI Studio, `secrets edit admin/gemini_key`).
{
  systemSettings.admin.enable = true;
  systemSettings.admin.ai.enable = true;
}
