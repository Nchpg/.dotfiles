{
  config,
  lib,
  myLib,
  ...
}:

myLib.mkPackageModule {
  inherit config lib;
  dir = ./.;
  description = "ncdu (analyseur d'occupation disque)";
}
