{ pkgs-stable, pkgs-unstable, ... }:

{
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # ESP de 256 Mo (~31 Mo/génération) : au-delà de 5, /boot sature avant l'élagage.
  boot.loader.systemd-boot.configurationLimit = 5;

  # evdi 1.14 ne compile plus sur 7.2 : recette d'unstable ; retirer quand stable >= 1.15.
  boot.kernelPackages = pkgs-stable.linuxPackages_latest.extend (
    kfinal: _: {
      evdi = kfinal.callPackage "${pkgs-unstable.path}/pkgs/os-specific/linux/evdi" { };
    }
  );

  boot.tmp.cleanOnBoot = true;
}
