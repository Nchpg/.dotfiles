{
  config,
  lib,
  pkgs-stable,
  pkgs-unstable,
  ...
}:

let
  cfg = config.systemSettings.hardware.intelGraphics;

  # Limite effective sur Meteor Lake : celle du MMIO, que règle thermald (la MSR, elle, reste à 200 W).
  pl1 = "/sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw";
  pl1Micro = toString (cfg.powerLimit * 1000000);

  # Interrupteur du mode « performance-max » (lg-control), écrit par le groupe wheel : sans lui, le profil
  # performance reste celui de power-profiles-daemon, sans plancher.
  maxSwitch = "/var/lib/power-limit/performance-max";
in
{
  options = {
    systemSettings.hardware.intelGraphics = {
      enable = lib.mkEnableOption "GPU Intel Arc/Xe (driver xe + OpenCL/Level-Zero/VA-API)";

      powerLimit = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        example = 16;
        description = ''
          Plancher de la limite de puissance longue durée (PL1, en watts), partagée par le CPU et le GPU, en mode
          « performance-max » : profil performance de power-profiles-daemon et interrupteur
          /var/lib/power-limit/performance-max à 1 (lg-control). Ailleurs, et avec `null` : celle que thermald tire
          des tables du constructeur (DPTF), qui la fait varier avec la température.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        services.thermald.enable = true;

        services.xserver.videoDrivers = [ "modesetting" ];

        environment.systemPackages = [
          pkgs-stable.nvtopPackages.intel
          pkgs-stable.clinfo
        ];

        # iGPU Meteor Lake sur xe ; i915 peut geler le compute (inverser ces deux params).
        boot.kernelParams = [
          "i915.force_probe=!7d55"
          "xe.force_probe=7d55"
        ];
        boot.kernelModules = [ "xe" ];
        boot.initrd.kernelModules = [ "xe" ];

        hardware.graphics = {
          enable = true;
          extraPackages = [
            pkgs-unstable.intel-compute-runtime
            pkgs-unstable.level-zero
            # Média en stable : la libva stable (2.23) ne sait pas appeler le driver unstable.
            pkgs-stable.intel-media-driver
            pkgs-stable.vpl-gpu-rt
          ];
        };

        environment.sessionVariables = {
          LIBVA_DRIVER_NAME = "iHD";
        };

        programs.nix-ld.libraries = [ pkgs-stable.libva ];
      }

      # thermald (--adaptive) garde la gestion thermique : il baisse la PL1 quand le processeur chauffe, la remonte
      # à froid, d'où un contrôle toutes les 30 s (et 30 s au plus après un réveil). Seulement en performance-max,
      # et en plancher : thermald peut accorder plus à froid ; en quittant ce mode, sa valeur est rendue.
      (lib.mkIf (cfg.powerLimit != null) {
        assertions = [
          {
            assertion = config.services.power-profiles-daemon.enable;
            message = "systemSettings.hardware.intelGraphics.powerLimit suit le profil de power-profiles-daemon.";
          }
        ];

        systemd.services.power-limit = {
          description = "Limite de puissance longue durée du processeur (au moins ${toString cfg.powerLimit} W en performance-max)";
          after = [
            "thermald.service"
            "power-profiles-daemon.service"
          ];
          unitConfig.ConditionPathExists = pl1;
          serviceConfig.Type = "oneshot";
          path = [ config.services.power-profiles-daemon.package ];
          script = ''
            saved=/run/power-limit/thermald
            # Présent tant que le plancher s'applique : lu par les affichages (lg-control, barre).
            floor=/run/power-limit/floor
            mkdir -p /run/power-limit
            current=$(cat ${pl1})
            if [ "$(cat ${maxSwitch} 2>/dev/null)" = 1 ] && [ "$(powerprofilesctl get)" = performance ]; then
              echo ${pl1Micro} > "$floor"
              if [ "$current" -lt ${pl1Micro} ]; then
                echo "$current" > "$saved"
                echo ${pl1Micro} > ${pl1}
              fi
            else
              rm -f "$floor"
              if [ "$current" = ${pl1Micro} ] && [ -s "$saved" ]; then
                cat "$saved" > ${pl1}
              fi
            fi
          '';
        };

        systemd.tmpfiles.rules = [
          "d /var/lib/power-limit 0755 root root -"
          "f ${maxSwitch} 0664 root wheel - 0"
        ];

        # Changement de profil (power-profiles-daemon le réécrit dans son fichier) ou de l'interrupteur : aussitôt.
        systemd.paths.power-limit = {
          wantedBy = [ "multi-user.target" ];
          pathConfig.PathChanged = [
            "/var/lib/power-profiles-daemon/state.ini"
            maxSwitch
          ];
        };

        systemd.timers.power-limit = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "30s";
            OnUnitActiveSec = "30s";
            AccuracySec = "5s";
          };
        };
      })
    ]
  );
}
