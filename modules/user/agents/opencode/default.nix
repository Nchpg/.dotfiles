{
  config,
  lib,
  pkgs-unstable,
  myLib,
  ...
}:

myLib.mkPackageModule {
  inherit config lib;
  dir = ./.;
  description = "OpenCode CLI";
  defaultPkgs = pkgs-unstable;
}
