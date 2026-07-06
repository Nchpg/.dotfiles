{ pkgs-stable, ... }:

{
  # Bootloader UEFI (systemd-boot).
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Borne les entrées du menu de boot (kernels/initrds copiés sur l'ESP, petite
  # partition) : au-delà, les vieilles générations restent dans le store (gc /
  # genclean décident de leur sort) mais sortent du menu.
  boot.loader.systemd-boot.configurationLimit = 15;

  # Dernier noyau stable de nixpkgs (support du matériel récent, cf. le GPU
  # Meteor Lake dans modules/system/intel-graphics).
  boot.kernelPackages = pkgs-stable.linuxPackages_latest;
}
