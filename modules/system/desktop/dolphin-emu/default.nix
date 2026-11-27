{ config, lib, ... }:

let
  users = lib.filter (u: u.userSettings.apps.dolphinEmu.enable) (
    lib.attrValues config.home-manager.users
  );
in
{
  # Règles udev du paquet (uaccess) : DolphinBar et adaptateur GameCube en USB.
  # Les Wiimotes en Bluetooth passent par BlueZ et n'en ont pas besoin.
  services.udev.packages = map (u: u.userSettings.apps.dolphinEmu.package) users;
}
