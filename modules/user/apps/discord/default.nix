{
  config,
  lib,
  myLib,
  ...
}:

# Gaté par profil : root/guest n'ont aucune raison d'embarquer Discord.
myLib.mkPackageModule {
  inherit config lib;
  path = [
    "apps"
    "discord"
  ];
  description = "Discord";
}
