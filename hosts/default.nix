{ lib, target, ... }:

let
  hardwareConfig = ./. + "/${target.host}/hardware-configuration.nix";
in
{
  # Gardé par pathExists + assertion : sinon "path does not exist" cryptique.
  imports =
    lib.optional (builtins.pathExists hardwareConfig) hardwareConfig
    ++ (lib.optional (builtins.pathExists (./. + "/${target.host}/configuration.nix")) (
      ./. + "/${target.host}/configuration.nix"
    ));

  config.assertions = [
    {
      assertion = builtins.pathExists hardwareConfig;
      message = "hosts/${target.host}/hardware-configuration.nix est introuvable : génère-le avec `nixos-generate-config` sur la machine.";
    }
  ];
}
