{ pkgs-stable, ... }:

{
  # Bootloader UEFI (systemd-boot).
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Dernier noyau stable de nixpkgs (support du matériel récent, cf. le GPU
  # Meteor Lake dans modules/system/intel-graphics).
  boot.kernelPackages = pkgs-stable.linuxPackages_latest;
}
