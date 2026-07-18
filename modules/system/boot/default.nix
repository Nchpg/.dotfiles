{ pkgs-stable, ... }:

{
  # Bootloader UEFI (systemd-boot).
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Borne les entrées du menu de boot (kernels/initrds copiés sur l'ESP, petite
  # partition) : au-delà, les vieilles générations restent dans le store (gc /
  # genclean décident de leur sort) mais sortent du menu.
  #
  # 5 et pas plus : l'ESP fait 256 Mo et chaque génération y pèse ~31 Mo
  # (noyau + initrd), soit ~8 générations maximum. Une limite supérieure n'est
  # pas atteignable — la partition se remplit AVANT que systemd-boot n'élague,
  # et le rebuild échoue en « No space left on device » sur /boot alors que /
  # est encore large. 5 × 31 Mo ≈ 155 Mo, marge confortable.
  boot.loader.systemd-boot.configurationLimit = 5;

  # Dernier noyau stable de nixpkgs (support du matériel récent, cf. le GPU
  # Meteor Lake dans modules/system/intel-graphics). Compromis assumé : un
  # bump de kernel peut casser le module hors-arbre evdi (displaylink) ou
  # aggraver les gels GPU déjà documentés dans modules/system/ollama.
  boot.kernelPackages = pkgs-stable.linuxPackages_latest;

  # Vide /tmp à chaque boot : il vit sur la racine ext4 et rien ne le purgeait
  # (les restes de builds/téléchargements s'accumulaient indéfiniment).
  boot.tmp.cleanOnBoot = true;
}
