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

  # Santé du NVMe : smartd sonde les compteurs SMART (usure, blocs de réserve,
  # erreurs média) toutes les 30 min et alerte via le journal quand ça se
  # dégrade — signal précoce d'un SSD mourant, des semaines avant la panne.
  # Complète fstrim (perf) et fwupd (firmware) ; fournit aussi smartctl pour
  # un check manuel (smartctl -a /dev/nvme0).
  # Notifications desktop via systembus-notify (comme earlyoom — qui active
  # déjà ce daemon : le laisser à false ici créerait un conflit d'éval).
  services.smartd = {
    enable = true;
    notifications.systembus-notify.enable = true;
  };

  programs.thunar.enable = true;
}
