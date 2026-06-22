# Native Intel Arc (XPU) PyTorch dev shell — no Ubuntu container.
#
# Pass `pkgs = pkgs-unstable` so the Intel runtime matches the system graphics
# stack (intel-compute-runtime / level-zero from nixos-unstable).
#
# The trick that makes it work on NixOS:
#   * nixpkgs' intel-compute-runtime splits the Level-Zero GPU driver
#     (libze_intel_gpu.so) into a SEPARATE `drivers` output. The system only
#     pulls the default `out` (OpenCL) output, so that L0 driver is never
#     realized by default. We reference `intel-compute-runtime.drivers`
#     explicitly and point the Level-Zero loader at it via ZE_ENABLE_ALT_DRIVERS.
#   * PyTorch XPU itself is the official wheel from download.pytorch.org/whl/xpu,
#     installed into a uv venv (see shellHook). torch is a Python extension, so
#     it just needs its deps on LD_LIBRARY_PATH — no FHS env required.
{ pkgs }:

let
  icr = pkgs.intel-compute-runtime;            # OpenCL driver + ocloc (out)
  l0drv = icr.drivers;                          # libze_intel_gpu.so (Level-Zero)
  igc = pkgs.intel-graphics-compiler;

  # Runtime libraries the torch-xpu wheel + Intel L0 driver need at load time.
  runtimeLibs = [
    pkgs.level-zero
    icr
    l0drv
    igc
    pkgs.intel-gmmlib
    pkgs.ocl-icd
    pkgs.stdenv.cc.cc.lib
    pkgs.zlib
    pkgs.libxml2
    pkgs.ncurses
  ];

  ldPath = pkgs.lib.makeLibraryPath runtimeLibs
    + ":${igc}/lib/igc2"
    + ":${icr}/lib/intel-opencl";
in
pkgs.mkShell {
  name = "xpu-dev";

  packages = [
    pkgs.python313
    pkgs.uv
    pkgs.clinfo            # `clinfo` to sanity-check the GPU is visible
    pkgs.level-zero        # ze_* headers/loader
  ];

  # Make the Intel runtime discoverable, and tell the L0 loader where the
  # (otherwise orphaned) GPU driver lives.
  LD_LIBRARY_PATH = ldPath;
  ZE_ENABLE_ALT_DRIVERS = "${l0drv}/lib/libze_intel_gpu.so.1";
  ONEAPI_DEVICE_SELECTOR = "level_zero:gpu";

  shellHook = ''
    # If a venv is already active, expose any libs it bundles (e.g. torch-xpu's
    # SYCL / oneAPI runtime, which lands in $VIRTUAL_ENV/lib). Usually torch's
    # own rpath already finds them, so this is just a safety net.
    if [ -n "$VIRTUAL_ENV" ]; then
      export LD_LIBRARY_PATH="$VIRTUAL_ENV/lib:$LD_LIBRARY_PATH"
    fi

    echo "⚡ Python dev shell — Intel XPU ready"
    echo
    echo "  venv:       uv venv .venv && source .venv/bin/activate"
    echo "  packages:   uv pip install <pkg>            # numpy pandas matplotlib …"
    echo "              uv pip install -r requirements.txt"
    echo
    echo "  PyTorch on the Arc GPU (XPU) — install from the xpu wheel index:"
    echo "    uv pip install torch --index-url https://download.pytorch.org/whl/xpu"
    echo "    python -c \"import torch; print(torch.xpu.is_available(), torch.xpu.get_device_name(0))\""
    echo "    # if torch can't load its libs: export LD_LIBRARY_PATH=\"\$VIRTUAL_ENV/lib:\$LD_LIBRARY_PATH\""
    echo
    echo "  GPU check:  clinfo | grep 'Device Name'"
  '';
}
