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
          Limite de puissance longue durée (PL1, en watts), partagée par le CPU et le GPU. `null` :
          celle que thermald tire des tables du constructeur (DPTF).
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
      (lib.mkIf (cfg.powerLimit != null) {
        systemd.services.power-limit = {
          description = "Limite de puissance longue durée du processeur (PL1 à ${toString cfg.powerLimit} W)";
          after = [ "thermald.service" ];
          unitConfig.ConditionPathExists = pl1;
          serviceConfig.Type = "oneshot";
          script = ''
            [ "$(cat ${pl1})" = ${pl1Micro} ] || echo ${pl1Micro} > ${pl1}
          '';
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
