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
    "ncdu"
  ];
  description = "ncdu (analyseur d'occupation disque)";
}
