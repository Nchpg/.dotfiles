{
  config,
  lib,
  myLib,
  ...
}:

myLib.mkPackageModule {
  inherit config lib;
  dir = ./.;
  description = "broot (navigateur d'arborescence)";
}
