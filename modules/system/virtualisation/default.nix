{
  config,
  lib,
  pkgs-stable,
  ...
}:

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
