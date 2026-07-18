# Option "pkgs" répétée à l'identique dans presque tous les modules
# modules/user/* (permet à un profil de choisir stable/unstable par module,
# via userSettings.defaultPkgs comme valeur par défaut commune).
{ lib, config }:
lib.mkOption {
  type = lib.types.pkgs;
  default = config.userSettings.defaultPkgs;
  description = "Pkgs to use";
}
