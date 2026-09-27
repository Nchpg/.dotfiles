{
  config,
  lib,
  pkgs-stable,
  pkgs-unstable,
  ...
}:

# GPU Intel Arc (Meteor Lake) : driver xe, OpenCL/Level-Zero, VA-API.
# Spécifique au matériel -> activé par le host, pas par le profil.
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
    # Pilote les P-states/RAPL pour réduire le throttling (spécifique Intel :
    # DPTF/P-state driver, no-op sur AMD).
    services.thermald.enable = true;

    services.xserver.videoDrivers = [ "modesetting" ];

    # nvtop.intel (pas .full, inutile sans NVIDIA/AMD) + clinfo, pas dans le
    # PATH via extraPackages.
    environment.systemPackages = [
      pkgs-stable.nvtopPackages.intel
      pkgs-stable.clinfo
    ];

    # iGPU Meteor Lake (PCI 7d55) sur driver xe. Repasser sur i915 (peut geler
    # le compute, cf. ollama) = inverser ces deux params.
    boot.kernelParams = [
      "i915.force_probe=!7d55"
      "xe.force_probe=7d55"
    ];
    boot.kernelModules = [ "xe" ];
    # Chargé dès l'initrd (stage 1) : réduit le flicker/tearing avant que le
    # vrai KMS ne prenne le relais (cf. nixos-hardware common/gpu/intel).
    boot.initrd.kernelModules = [ "xe" ];

    # unstable pour suivre le matériel récent (aligné avec le devshell xpu).
    hardware.graphics = {
      enable = true;
      extraPackages = with pkgs-unstable; [
        intel-compute-runtime # OpenCL + Level-Zero (libze_intel_gpu.so)
        intel-media-driver
        vpl-gpu-rt
        level-zero
      ];
    };

    environment.sessionVariables = {
      LIBVA_DRIVER_NAME = "iHD";
    };
  };
}
