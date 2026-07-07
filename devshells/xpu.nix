# PyTorch natif sur Intel Arc (XPU) — hérite du devshell python.
# Recevoir `pkgs = pkgs-unstable` pour matcher la stack graphique système
# (intel-compute-runtime / level-zero de nixos-unstable).
#
# Ce qui fait marcher ça sur NixOS :
#   * intel-compute-runtime range le driver GPU Level-Zero
#     (libze_intel_gpu.so) dans un output `drivers` SÉPARÉ que le système ne
#     réalise jamais par défaut — on le référence explicitement et on le
#     donne au loader via ZE_ENABLE_ALT_DRIVERS.
#   * torch-xpu est le wheel officiel (download.pytorch.org/whl/xpu) installé
#     dans un venv uv : simple extension python, il suffit que ses deps
#     soient sur LD_LIBRARY_PATH — pas besoin de FHS env.
{ pkgs }:

let
  icr = pkgs.intel-compute-runtime; # driver OpenCL + ocloc (out)
  l0drv = icr.drivers; # libze_intel_gpu.so (Level-Zero)
  igc = pkgs.intel-graphics-compiler;
in
import ./python.nix {
  inherit pkgs;
  name = "xpu-dev";

  extraPackages = [
    pkgs.clinfo # sanity-check GPU : clinfo | grep 'Device Name'
    pkgs.level-zero # headers/loader ze_*
  ];

  # Libs runtime du wheel torch-xpu + driver Intel (les libs génériques —
  # gcc.lib, zlib, … — viennent déjà de python.nix).
  extraLibs = [
    pkgs.level-zero
    icr
    l0drv
    igc
    pkgs.intel-gmmlib
    pkgs.ocl-icd
  ];
  extraLdPaths = [
    "${igc}/lib/igc2"
    "${icr}/lib/intel-opencl"
  ];

  extraEnv = {
    ZE_ENABLE_ALT_DRIVERS = "${l0drv}/lib/libze_intel_gpu.so.1";
    ONEAPI_DEVICE_SELECTOR = "level_zero:gpu";
  };

  extraShellHook = ''
    # Filet de sécurité : exposer les libs embarquées par le venv (runtime
    # SYCL/oneAPI du wheel torch-xpu) si un venv est déjà actif.
    if [ -n "$VIRTUAL_ENV" ]; then
      export LD_LIBRARY_PATH="$VIRTUAL_ENV/lib:$LD_LIBRARY_PATH"
    fi

    echo
    echo "⚡ Intel XPU ready"
    echo "  torch:  uv pip install torch --index-url https://download.pytorch.org/whl/xpu"
    echo "  check:  python -c \"import torch; print(torch.xpu.is_available())\""
  '';
}
