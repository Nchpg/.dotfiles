{ pkgs-stable, ... }:

{
  # udisks2 : montage sans root (D-Bus + polkit). Thunar en gestionnaire.
  services.udisks2.enable = true;
  boot.supportedFilesystems = [ "ntfs" ];

  # Couche "volumes" de Thunar (montage USB, corbeille, MTP) : dépendance
  # cachée du module GNOME, à activer explicitement.
  services.gvfs.enable = true;

  # ext4 sans option discard : rien d'autre ne trimait le NVMe.
  services.fstrim.enable = true;

  # Alerte via le journal si les compteurs SMART se dégradent (signal
  # précoce avant panne). Notification desktop via systembus-notify — déjà
  # activé par earlyoom, le laisser à false ici créerait un conflit d'éval.
  services.smartd = {
    enable = true;
    notifications.systembus-notify.enable = true;
  };

  # Les commandes admin NVMe exigent CAP_SYS_ADMIN : waybar (user) ne peut
  # pas appeler smartctl lui-même, d'où cet export périodique vers
  # /run/nvme-health/ (lisible sans root), consommé par disk.sh.
  systemd.services.nvme-health-export = {
    description = "Exporte la santé SMART des NVMe vers /run/nvme-health";
    unitConfig.ConditionPathExistsGlob = "/dev/nvme[0-9]"; # pas de NVMe -> pas d'unit failed
    serviceConfig = {
      Type = "oneshot";
      RuntimeDirectory = "nvme-health";
      RuntimeDirectoryPreserve = true; # doit survivre entre deux ticks du timer
      ExecStart = pkgs-stable.writeShellScript "nvme-health-export" ''
        set -euo pipefail
        PATH=${pkgs-stable.smartmontools}/bin:${pkgs-stable.coreutils}/bin
        for dev in /dev/nvme[0-9]; do
          [ -e "$dev" ] || continue
          out="/run/nvme-health/$(basename "$dev").json"
          # smartctl sort != 0 sur certains warnings SMART, JSON quand même valide.
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
