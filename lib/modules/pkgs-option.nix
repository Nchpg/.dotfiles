{
  lib,
  config,
  default ? config.userSettings.defaultPkgs,
}:
lib.mkOption {
  type = lib.types.pkgs;
  inherit default;
  description = "Pkgs to use";
}
