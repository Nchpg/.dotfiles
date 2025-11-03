{ config, lib, target, ... }:

{
  imports = [
    (./. + "/${target.host}/hardware-configuration.nix")
  ] ++ (lib.optional (builtins.pathExists (./. + "/${target.host}/configuration.nix")) (./. + "/${target.host}/configuration.nix"));
}