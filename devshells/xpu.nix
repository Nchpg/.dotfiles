# PyTorch natif sur Intel Arc (XPU), hérite du devshell python. `pkgs` doit
# être pkgs-unstable pour matcher la stack graphique système.
#
# intel-compute-runtime range le driver Level-Zero (libze_intel_gpu.so) dans
# un output `drivers` SÉPARÉ que le système ne réalise jamais par défaut :
# référencé explicitement et donné au loader via ZE_ENABLE_ALT_DRIVERS.
# torch-xpu (wheel officiel) est une simple extension python : ses deps sur
# LD_LIBRARY_PATH suffisent, pas besoin de FHS env.
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

  # Libs génériques (gcc.lib, zlib...) déjà fournies par python.nix.
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
    # Filet : expose les libs embarquées par le venv si déjà actif.
    if [ -n "$VIRTUAL_ENV" ]; then
      export LD_LIBRARY_PATH="$VIRTUAL_ENV/lib:$LD_LIBRARY_PATH"
    fi

    echo
    echo "⚡ Intel XPU ready"
    echo "  torch:  uv pip install torch --index-url https://download.pytorch.org/whl/xpu"
    echo "  check:  python -c \"import torch; print(torch.xpu.is_available())\""
  '';
}
