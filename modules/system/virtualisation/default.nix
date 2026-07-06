{
  config,
  lib,
  pkgs-stable,
  ...
}:

# Docker et libvirt (KVM/QEMU), activables séparément par profil.
# L'accès des users est géré à part : options allowDocker / allowLibvirt
# dans modules/system/users (groupes docker / libvirtd, quasi root-équivalents).
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
      virtualisation.docker = {
        enable = true;
        daemon.settings = {
          dns = [
            "8.8.8.8"
            "1.1.1.1"
          ];
        };
      };
    })

    (lib.mkIf cfg.libvirt.enable {
      virtualisation.libvirtd.enable = true;
      environment.systemPackages = [ pkgs-stable.virt-manager ];
    })
  ];
}
