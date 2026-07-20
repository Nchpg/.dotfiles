{
  config,
  lib,
  pkgs-stable,
  ...
}:

# Accès users géré à part : allowDocker/allowLibvirt dans modules/system/users.
let
  cfg = config.systemSettings.virtualisation;
in
{
  options = {
    systemSettings.virtualisation = {
      docker.enable = lib.mkEnableOption "Docker";
      libvirt.enable = lib.mkEnableOption "libvirt (KVM/QEMU) + virt-manager";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.docker.enable {
      virtualisation.docker.enable = true;
    })

    (lib.mkIf cfg.libvirt.enable {
      virtualisation.libvirtd.enable = true;
      environment.systemPackages = [ pkgs-stable.virt-manager ];
    })
  ];
}
