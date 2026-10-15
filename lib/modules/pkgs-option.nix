# Option "pkgs" répétée à l'identique dans presque tous les modules
# modules/user/* (permet à un profil de choisir stable/unstable par module,
# via userSettings.defaultPkgs comme valeur par défaut commune). `default` se
# surcharge au cas par cas (ex. rofi, qui a besoin d'unstable par défaut).
{
  lib,
  config,
  default ? config.userSettings.defaultPkgs,
}:
lib.mkOption {
  type = lib.types.pkgs;
  inherit default;
  description = "Pkgs to use";
}
