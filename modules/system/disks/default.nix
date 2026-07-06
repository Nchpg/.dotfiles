{ ... }:

{
  # Disques externes : udisks2 (montage sans root, via D-Bus + polkit) + NTFS
  # pour les disques Windows. Thunar comme gestionnaire de fichiers : cliquer
  # sur une clé USB la monte via udisks2 dans /run/media/<user>/.
  # (udiskie, l'automount au branchement, a été retiré : son service était
  # cassé depuis des mois — lien systemd mort — sans que ça manque.)
  services.udisks2.enable = true;
  boot.supportedFilesystems = [ "ntfs" ];

  # gvfs : la couche « volumes » de Thunar (montage des clés USB via udisks2,
  # corbeille, MTP…). Il n'était fourni qu'indirectement par le module GNOME —
  # dépendance cachée : sans session GNOME, Thunar ne monterait plus rien.
  services.gvfs.enable = true;

  # TRIM hebdomadaire du SSD (fstrim.timer) : ext4 sans option discard, rien ne
  # trimait le NVMe jusqu'ici.
  services.fstrim.enable = true;

  programs.thunar.enable = true;
}
