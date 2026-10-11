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

    hardware.graphics = {
      enable = true;
      extraPackages = [
        # Compute en unstable pour suivre le matériel récent (aligné avec le
        # devshell xpu).
        pkgs-unstable.intel-compute-runtime # OpenCL + Level-Zero (libze_intel_gpu.so)
        pkgs-unstable.level-zero
        # Média en STABLE : chargés DANS les applis (Firefox, Chrome, mpv...),
        # donc liés à la libva de ces applis, construites sur stable. Le driver
        # unstable n'exporte que __vaDriverInit_1_24, que la libva stable (2.23)
        # ne sait pas appeler -> VA-API refusé, décodage CPU partout. Le
        # stable exporte 1_23 ET 1_24 : marche aussi avec une libva plus
        # récente.
        pkgs-stable.intel-media-driver
        pkgs-stable.vpl-gpu-rt
      ];
    };

    environment.sessionVariables = {
      LIBVA_DRIVER_NAME = "iHD";
    };

    # VA-API pour les binaires non-Nix (FilmCraft...), même nixpkgs que le
    # driver ci-dessus.
    programs.nix-ld.libraries = [ pkgs-stable.libva ];
  };
}
