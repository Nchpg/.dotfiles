{ config, lib, ... }:

{
  config = lib.mkForce {
    systemSettings = {
      # Special system config for this host if needed (example use grub rather than systemd-boot ...};
      # This config will overwrite profile config thank to "mkForce"
      # ...

    };
  };
}