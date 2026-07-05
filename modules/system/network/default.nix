{ target, ... }:

{
  # Hostname = "<profil>-<host>" (aligné sur le nom de la cible du flake, ce qui
  # permet à `nixos-rebuild --flake .#$(hostname)` de tomber juste).
  networking.hostName = "${target.profile}-${target.host}";

  # NetworkManager gère les interfaces (DHCP inclus), on coupe le DHCP global.
  networking.networkmanager.enable = true;
  networking.useDHCP = false;
}
