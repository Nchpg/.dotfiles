{ lib, target, ... }:

let
  hardwareConfig = ./. + "/${target.host}/hardware-configuration.nix";
in
{
  imports =
    lib.optional (builtins.pathExists hardwareConfig) hardwareConfig
    ++ (lib.optional (builtins.pathExists (./. + "/${target.host}/configuration.nix")) (
      ./. + "/${target.host}/configuration.nix"
    ));

  config = {
    assertions = [
      {
        assertion = builtins.pathExists hardwareConfig;
        message = "hosts/${target.host}/hardware-configuration.nix est introuvable : génère-le avec `nixos-generate-config` sur la machine.";
      }
    ];

    # Élargir la liste élargit les secrets déchiffrables.
    systemSettings.sops.deployments = {
      think = [ "server" ];
      gram = [ "personal" ];
    };
  };
}
