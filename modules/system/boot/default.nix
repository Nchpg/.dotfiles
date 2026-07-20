{ pkgs-stable, ... }:

{
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # ESP de 256 Mo, ~31 Mo/génération : au-delà de 5, la partition se remplit
  # AVANT que systemd-boot n'élague, et le rebuild échoue en "No space left
  # on device" sur /boot alors que / est encore large.
  boot.loader.systemd-boot.configurationLimit = 5;

  # Dernier noyau stable (support matériel récent, cf. intel-graphics). Un
  # bump peut casser evdi (displaylink) hors-arbre ou aggraver les gels GPU
  # documentés dans modules/system/ollama.
  boot.kernelPackages = pkgs-stable.linuxPackages_latest;

  # /tmp vit sur la racine ext4, rien d'autre ne le purgeait.
  boot.tmp.cleanOnBoot = true;
}
