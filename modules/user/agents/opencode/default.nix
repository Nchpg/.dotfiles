{
  config,
  lib,
  pkgs-unstable,
  myLib,
  ...
}:

myLib.mkPackageModule {
  inherit config lib;
  path = [
    "agents"
    "opencode"
  ];
  description = "OpenCode CLI";
  defaultPkgs = pkgs-unstable;
}
