{ config, ... }:

let
  desktop = config.systemSettings.desktop.enable;
in
{
  services.printing.enable = desktop;
  # cups-browsed : historique de failles réseau (CVE-2024-47176), avahi suffit.
  services.printing.browsed.enable = false;

  services.avahi = {
    enable = desktop;
    nssmdns4 = desktop;
  };
}
