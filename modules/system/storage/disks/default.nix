{
  config,
  lib,
  pkgs-stable,
  ...
}:

let
  desktop = config.systemSettings.desktop.enable;
in
lib.mkMerge [
  {
    boot.supportedFilesystems = [ "ntfs" ];

    services.fstrim.enable = true;

    services.smartd = {
      enable = true;
      notifications.systembus-notify.enable = true;
    };
  }

  (lib.mkIf desktop {
    services.udisks2.enable = true;

    services.gvfs.enable = true;
    environment.systemPackages = [ pkgs-stable.wsdd ];

    programs.thunar.enable = true;
    services.tumbler.enable = true;

    # Les commandes NVMe exigent CAP_SYS_ADMIN : export périodique vers /run/nvme-health/.
    systemd.services.nvme-health-export = {
      description = "Exporte la santé SMART des NVMe vers /run/nvme-health";
      unitConfig.ConditionPathExistsGlob = "/dev/nvme[0-9]";
      serviceConfig = {
        Type = "oneshot";
        RuntimeDirectory = "nvme-health";
        RuntimeDirectoryPreserve = true;
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
  })
]
