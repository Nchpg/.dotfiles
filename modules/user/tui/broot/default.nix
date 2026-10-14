{
  config,
  lib,
  myLib,
  ...
}:

myLib.mkPackageModule {
  inherit config lib;
  path = [
    "tui"
    "broot"
  ];
  description = "broot (navigateur d'arborescence)";
}
