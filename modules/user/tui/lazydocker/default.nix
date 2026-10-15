{
  config,
  lib,
  myLib,
  ...
}:

myLib.mkPackageModule {
  inherit config lib;
  dir = ./.;
  description = "lazydocker (TUI Docker)";
}
