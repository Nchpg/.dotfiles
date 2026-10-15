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
  description = "Codex CLI";
  defaultPkgs = pkgs-unstable;
}
