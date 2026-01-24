{ pkgs}:

pkgs.mkShell {
  name = "c-dev";

  buildInputs = [
    pkgs.gcc
    pkgs.gdb
    pkgs.cmake
    pkgs.valgrind
  ];

  shellHook = ''
    echo "⚙️ C dev shell ready"
    export NIX_DEV_SHELL_NAME="c"
  '';
}
