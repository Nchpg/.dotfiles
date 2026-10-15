{
  config,
  lib,
  myLib,
  ...
}:

myLib.mkPackageModule {
  inherit config lib;
  dir = ./.;
  description = "lazysql (TUI client SQL)";
}
