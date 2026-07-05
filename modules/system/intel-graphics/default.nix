{ config, lib, pkgs-unstable, ... }:

# GPU Intel Arc (Meteor Lake) : driver xe, OpenCL/Level-Zero, VA-API.
# Spécifique au matériel → activé par le host (hosts/gram/configuration.nix),
# pas par le profil.
let
  cfg = config.systemSettings.intelGraphics;
in {
  options = {
    systemSettings.intelGraphics = {
      enable = lib.mkEnableOption "GPU Intel Arc/Xe (driver xe + OpenCL/Level-Zero/VA-API)";
    };
  };

  config = lib.mkIf cfg.enable {
    services.xserver.videoDrivers = [ "modesetting" ];

    # L'iGPU Meteor Lake (PCI 7d55) est pris par le driver `xe` (moderne) au
    # lieu de i915. NOTE : xe peut intermittemment geler le compute GPU sur
    # cette machine (cf. ollama) — repasser sur i915 = inverser ces deux params.
    boot.kernelParams = [ "i915.force_probe=!7d55" "xe.force_probe=7d55" ];
    boot.kernelModules = [ "xe" ];

    # Stack compute/vidéo depuis unstable pour suivre le matériel récent
    # (aligné avec le devshell xpu, cf. flake.nix).
    hardware.graphics = {
      enable = true;
      extraPackages = with pkgs-unstable; [
        intel-compute-runtime            # OpenCL driver (libigdrcl.so)
        intel-compute-runtime.drivers    # Level-Zero GPU driver (libze_intel_gpu.so) -> /run/opengl-driver/lib
        intel-media-driver
        vpl-gpu-rt
        level-zero
      ];
    };

    environment.sessionVariables = {
      # Décodage vidéo VA-API via intel-media-driver.
      LIBVA_DRIVER_NAME = "iHD";
      # /!\ Compromis sécurité assumé : désactive le sandbox RDD de Firefox
      # pour que le décodage VA-API fonctionne. À retester sans, un jour.
      MOZ_DISABLE_RDD_SANDBOX = "1";
    };
  };
}
