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
    "codex"
  ];
  description = "Codex CLI";
  defaultPkgs = pkgs-unstable;
}
