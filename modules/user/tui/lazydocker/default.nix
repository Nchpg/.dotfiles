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
    "lazydocker"
  ];
  description = "lazydocker (TUI Docker)";
}
