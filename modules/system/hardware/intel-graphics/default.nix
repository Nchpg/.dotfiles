{
  config,
  lib,
  pkgs-stable,
  pkgs-unstable,
  ...
}:

let
  cfg = config.systemSettings.hardware.intelGraphics;
in
{
  options = {
    systemSettings.hardware.intelGraphics = {
      enable = lib.mkEnableOption "GPU Intel Arc/Xe (driver xe + OpenCL/Level-Zero/VA-API)";
    };
  };

  config = lib.mkIf cfg.enable {
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
  };
}
