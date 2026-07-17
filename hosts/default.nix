{ lib, target, ... }:

let
  hardwareConfig = ./. + "/${target.host}/hardware-configuration.nix";
in
{
  # Import gardé par pathExists + assertion : sans ça, ajouter un host sans
  # hardware-configuration.nix échouait avec un « path does not exist »
  # cryptique (même pattern que profiles/default.nix pour les users).
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
