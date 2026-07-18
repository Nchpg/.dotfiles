{ target, ... }:

let
  hostName = "${target.profile}-${target.host}";
in
{
  # Hostname = "<profil>-<host>" (aligné sur le nom de la cible du flake, ce qui
  # permet à `nixos-rebuild --flake .#$(hostname)` de tomber juste).
  networking.hostName = hostName;

  assertions = [
    {
      # RFC 1123 : lettres minuscules, chiffres, tirets (pas en 1er/dernier).
      # Sans ça, un futur profil/host mal nommé échouerait tard, au rebuild,
      # avec un message systemd peu clair.
      assertion = builtins.match "[a-z0-9]([a-z0-9-]*[a-z0-9])?" hostName != null;
      message = "networking.hostName \"${hostName}\" invalide (profil/host doivent être en minuscules alphanumériques + tirets, cf. RFC 1123).";
    }
  ];

  # NetworkManager gère les interfaces (DHCP inclus), on coupe le DHCP global.
  networking.networkmanager.enable = true;
  networking.useDHCP = false;
}
