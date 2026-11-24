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
          Limite de puissance longue durée (PL1, en watts), partagée par le CPU et le GPU, posée en profil
          « performance » de power-profiles-daemon. Dans les autres profils, et avec `null` : celle que thermald
          tire des tables du constructeur (DPTF).
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

      # thermald (--adaptive) garde la gestion thermique mais pose la PL1 des tables DPTF, et peut la reposer
      # (secteur, seuils de température) : elle est remise toutes les 30 s, et 30 s au plus après un réveil.
      # Seulement en profil performance : en le quittant, celle de thermald est rendue.
      (lib.mkIf (cfg.powerLimit != null) {
        assertions = [
          {
            assertion = config.services.power-profiles-daemon.enable;
            message = "systemSettings.hardware.intelGraphics.powerLimit suit le profil de power-profiles-daemon.";
          }
        ];

        systemd.services.power-limit = {
          description = "Limite de puissance longue durée du processeur (PL1 à ${toString cfg.powerLimit} W en profil performance)";
          after = [
            "thermald.service"
            "power-profiles-daemon.service"
          ];
          unitConfig.ConditionPathExists = pl1;
          serviceConfig.Type = "oneshot";
          path = [ config.services.power-profiles-daemon.package ];
          script = ''
            saved=/run/power-limit/thermald
            mkdir -p /run/power-limit
            current=$(cat ${pl1})
            if [ "$(powerprofilesctl get)" = performance ]; then
              if [ "$current" != ${pl1Micro} ]; then
                echo "$current" > "$saved"
                echo ${pl1Micro} > ${pl1}
              fi
            elif [ "$current" = ${pl1Micro} ] && [ -s "$saved" ]; then
              cat "$saved" > ${pl1}
            fi
          '';
        };

        # Changement de profil : power-profiles-daemon le réécrit dans ce fichier, appliqué aussitôt.
        systemd.paths.power-limit = {
          wantedBy = [ "multi-user.target" ];
          pathConfig.PathChanged = "/var/lib/power-profiles-daemon/state.ini";
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
