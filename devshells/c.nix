{ pkgs }:

pkgs.mkShell {
  name = "c-dev";

  # Outils exécutés en packages, bibliothèques linkées en buildInputs
  # (pkg-config les y découvre).
  packages = [
    pkgs.gcc
    pkgs.gdb
    pkgs.cmake
    pkgs.valgrind
    pkgs.pkg-config
  ];

  buildInputs = [
    pkgs.opencv
    pkgs.openblas
    pkgs.nlohmann_json
  ];

  shellHook = ''
    echo "⚙️ C dev shell ready"
    export NIX_DEV_SHELL_C="c"
  '';
}
