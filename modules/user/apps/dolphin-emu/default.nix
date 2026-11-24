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
  # Précondition : y déplacer Wii/, GC/ et Load/Riivolution/riivolution/save/ de ~/.local/share/dolphin-emu,
  # Dolphin fermé, avant le premier rebuild ; sinon home-manager refuse d'écraser les dossiers existants.
  saves = "${config.home.homeDirectory}/Nextcloud/Jeux/Dolphin";
in
{
  inherit (base) options;

  config = lib.mkMerge [
    base.config

    (lib.mkIf (cfg.enable && config.userSettings.apps.nextcloud.enable) {
      xdg.dataFile =
        lib.mapAttrs (_: dir: { source = config.lib.file.mkOutOfStoreSymlink "${saves}/${dir}"; })
          {
            "dolphin-emu/Wii" = "Wii";
            "dolphin-emu/GC" = "GC";
            # Mods Riivolution (Retro Rewind) : leur copie de la sauvegarde Wii, puis leur progression.
            "dolphin-emu/Load/Riivolution/riivolution/save" = "Riivolution";
          };
    })
  ];
}
