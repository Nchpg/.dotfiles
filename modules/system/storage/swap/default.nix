{ config, lib, ... }:

let
  cfg = config.systemSettings.storage.swap;
in
{
  options = {
    systemSettings.storage.swap = {
      zram.enable = lib.mkEnableOption "swap compressé en RAM (zram)";
      earlyoom.enable = lib.mkEnableOption "earlyoom (OOM-killer anticipé)";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.zram.enable {
      zramSwap = {
        enable = true;
        algorithm = "zstd";
        memoryPercent = 100;
        # Plus haut que le swap disque (-2 par défaut) : zram se remplit d'abord.
        priority = 100;
      };

      boot.kernel.sysctl = {
        "vm.swappiness" = 150;
        "vm.page-cluster" = 0;
      };
    })

    (lib.mkIf cfg.earlyoom.enable {
      # Ferait doublon avec earlyoom.
      systemd.oomd.enable = false;

      services.earlyoom = {
        enable = true;
        freeMemThreshold = 5;
        freeSwapThreshold = 5;
        # Upstream avertit qu'un user local peut spammer des notifs : sans risque en mono-user.
        enableNotifications = true;
        extraArgs = [
          "--prefer"
          "^(chrome|chromium|firefox)$"
          "--avoid"
          "^(sway|waybar|gdm|gnome-shell|Xwayland|systemd|dbus-daemon)$"
        ];
      };
    })
  ];
}
