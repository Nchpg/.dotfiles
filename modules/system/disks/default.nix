{ pkgs-stable, ... }:

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

  # Export périodique de la santé NVMe (JSON smartctl) vers /run/nvme-health/,
  # lisible sans root. Consommé par le tooltip du module disque de waybar
  # (modules/user/waybar/scripts/disk.sh). Nécessaire car les commandes admin
  # NVMe exigent CAP_SYS_ADMIN : un simple accès au device ne suffit pas, donc
  # waybar (user) ne peut pas appeler smartctl lui-même.
  systemd.services.nvme-health-export = {
    description = "Exporte la santé SMART des NVMe vers /run/nvme-health";
    # Pas de NVMe (autre host) → on ne lance rien, pas d'unit failed.
    unitConfig.ConditionPathExistsGlob = "/dev/nvme[0-9]";
    serviceConfig = {
      Type = "oneshot";
      RuntimeDirectory = "nvme-health";
      # Sans ça, systemd supprime /run/nvme-health dès que le oneshot se
      # termine — le fichier doit survivre entre deux ticks du timer.
      RuntimeDirectoryPreserve = true;
      ExecStart = pkgs-stable.writeShellScript "nvme-health-export" ''
        PATH=${pkgs-stable.smartmontools}/bin:${pkgs-stable.coreutils}/bin
        for dev in /dev/nvme[0-9]; do
          [ -e "$dev" ] || continue
          out="/run/nvme-health/$(basename "$dev").json"
          # smartctl sort ≠ 0 sur certains warnings SMART tout en produisant
          # un JSON valide : on garde le fichier dès qu'il est non vide.
          smartctl -H -A --json=c "$dev" > "$out.tmp" || true
          [ -s "$out.tmp" ] && mv "$out.tmp" "$out"
        done
      '';
    };
  };
  systemd.timers.nvme-health-export = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "5min";
    };
  };

  programs.thunar.enable = true;
}
