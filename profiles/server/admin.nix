{ ... }:

# Dashboard d'administration sur admin.vpn.<domaine> : mes appareils, puis Authelia en 2FA.
{
  systemSettings.admin = {
    enable = true;
    devices = [
      "gram"
      "windows_gram"
      "xiaomi_17t"
    ];
  };
}
