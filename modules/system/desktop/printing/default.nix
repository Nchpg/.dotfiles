{ config, ... }:

let
  desktop = config.systemSettings.desktop.enable;
in
# Suit systemSettings.desktop.enable : imprimer sert un poste de travail, pas
# une machine administrée en SSH.
{
  services.printing.enable = desktop;
  # cups-browsed (découverte d'imprimantes distantes) : historique de failles
  # exposées au réseau (CVE-2024-47176), et inutile ici, CUPS découvre déjà
  # les imprimantes IPP Everywhere via avahi ci-dessous.
  services.printing.browsed.enable = false;

  # mDNS / IPP Everywhere : sans ça CUPS ne voit que les imprimantes ajoutées
  # à la main. Seul service de bureau à ouvrir un port (5353/udp).
  services.avahi = {
    enable = desktop;
    nssmdns4 = desktop;
  };
}
