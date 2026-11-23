{
  config,
  lib,
  myLib,
  ...
}:

let
  base = myLib.mkPackageModule {
    inherit config lib;
    dir = ./.;
    description = "Dolphin (émulateur GameCube/Wii)";
  };

  cfg = config.userSettings.apps.dolphinEmu;

  # Progression des jeux (mémoire de la Wii, cartes mémoire GameCube), synchronisée par Nextcloud.
  # Précondition : y déplacer Wii/ et GC/ de ~/.local/share/dolphin-emu, Dolphin fermé, avant le
  # premier rebuild ; sinon home-manager refuse d'écraser les dossiers existants.
  saves = "${config.home.homeDirectory}/Nextcloud/Jeux/Dolphin";
in
{
  inherit (base) options;

  config = lib.mkMerge [
    base.config

    (lib.mkIf (cfg.enable && config.userSettings.apps.nextcloud.enable) {
      xdg.dataFile = lib.genAttrs [ "dolphin-emu/Wii" "dolphin-emu/GC" ] (path: {
        source = config.lib.file.mkOutOfStoreSymlink "${saves}/${baseNameOf path}";
      });
    })
  ];
}
