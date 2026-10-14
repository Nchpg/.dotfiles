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
    "lazysql"
  ];
  description = "lazysql (TUI client SQL)";
}
