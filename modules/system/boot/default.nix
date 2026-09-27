{ pkgs-stable, pkgs-unstable, ... }:

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
  #
  # evdi 1.14 (stable) ne compile plus sur 7.2 (API DRM drm_atomic_state ->
  # drm_atomic_commit) : on prend la recette d'unstable (1.15.1), compilée
  # contre CE noyau. À retirer quand stable passe evdi >= 1.15.
  boot.kernelPackages = pkgs-stable.linuxPackages_latest.extend (
    kfinal: _: {
      evdi = kfinal.callPackage "${pkgs-unstable.path}/pkgs/os-specific/linux/evdi" { };
    }
  );

  # /tmp vit sur la racine ext4, rien d'autre ne le purgeait.
  boot.tmp.cleanOnBoot = true;
}
