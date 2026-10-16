# `pkgs` doit être pkgs-unstable (stack graphique système).
{ pkgs }:

let
  icr = pkgs.intel-compute-runtime;
  igc = pkgs.intel-graphics-compiler;
in
import ./python.nix {
  inherit pkgs;
  name = "xpu-dev";

  extraPackages = [
    pkgs.clinfo
    pkgs.level-zero
  ];

  extraLibs = [
    pkgs.level-zero
    icr
    igc
    pkgs.intel-gmmlib
    pkgs.ocl-icd
  ];
  extraLdPaths = [
    "${igc}/lib/igc2"
    "${icr}/lib/intel-opencl"
  ];

  extraEnv = {
    ZE_ENABLE_ALT_DRIVERS = "${icr}/lib/libze_intel_gpu.so.1";
    ONEAPI_DEVICE_SELECTOR = "level_zero:gpu";
  };

  extraShellHook = ''
    if [ -n "$VIRTUAL_ENV" ]; then
      export LD_LIBRARY_PATH="$VIRTUAL_ENV/lib:$LD_LIBRARY_PATH"
    fi

    echo
    echo "⚡ Intel XPU ready"
    echo "  torch:  uv pip install torch --index-url https://download.pytorch.org/whl/xpu"
    echo "  check:  python -c \"import torch; print(torch.xpu.is_available())\""
  '';
}
