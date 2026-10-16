{
  config,
  lib,
  pkgs-stable,
  ...
}:

let
  cfg = config.systemSettings.hardware.lgLaptop;
  inherit (pkgs-stable) bash coreutils;

  fanMode = "/sys/devices/platform/lg-laptop/fan_mode";

  # Attribut vendeur LG (charge_control_end_threshold ne fait que le refléter).
  threshold = "/sys/devices/platform/lg-laptop/battery_care_limit";
in
{
  options = {
    systemSettings.hardware.lgLaptop = {
      enable = lib.mkEnableOption "réglages LG (driver lg-laptop) accessibles sans root";
      batteryCareLimit = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.enum [
            80
            100
          ]
        );
        default = null;
        example = 80;
        description = ''
          Plafond de charge batterie réappliqué au démarrage (80 ou 100). null = ne rien écrire.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="platform", KERNEL=="lg-laptop", RUN+="${coreutils}/bin/chgrp wheel ${fanMode}", RUN+="${coreutils}/bin/chmod g+w ${fanMode}"
    '';

    # Valeurs sysfs non persistantes, réécrites par un oneshot : udev est trop
    # tôt pour l'EC, et tmpfiles `w` saute sans erreur un chemin encore absent.
    systemd.services.lg-battery-care-limit = lib.mkIf (cfg.batteryCareLimit != null) {
      description = "Applique la limite de charge batterie LG";
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = threshold;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${bash}/bin/bash -c 'echo ${toString cfg.batteryCareLimit} > ${threshold}'";
      };
    };
  };
}
