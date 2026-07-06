{ ... }:

{
  # Disques externes : udisks2 (montage sans root, via D-Bus + polkit) + NTFS
  # pour les disques Windows. Thunar comme gestionnaire de fichiers : cliquer
  # sur une clé USB la monte via udisks2 dans /run/media/<user>/.
  # (udiskie, l'automount au branchement, a été retiré : son service était
  # cassé depuis des mois — lien systemd mort — sans que ça manque.)
  services.udisks2.enable = true;
  boot.supportedFilesystems = [ "ntfs" ];

  programs.thunar.enable = true;
}
