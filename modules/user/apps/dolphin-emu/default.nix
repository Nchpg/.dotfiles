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

  # Vibration des manettes DSU (le téléphone comme Wiimote, module wiimote) : le client DSU de Dolphin ne
  # l'envoyait pas au serveur. Le correctif lui ajoute une sortie « Motor » et le message « Rumble controller
  # motor » (0x110002) du protocole cemuhook. Dolphin est donc compilé ici, hors du cache.
  package = cfg.pkgs.dolphin-emu.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./dsu-rumble.patch ];
  });

  # Progression des jeux (mémoire de la Wii, cartes mémoire GameCube), synchronisée par Nextcloud.
  # Précondition : y déplacer Wii/, GC/ et Load/Riivolution/riivolution/save/ de ~/.local/share/dolphin-emu,
  # Dolphin fermé, avant le premier rebuild ; sinon home-manager refuse d'écraser les dossiers existants.
  saves = "${config.home.homeDirectory}/Nextcloud/Jeux/Dolphin";
in
{
  options = lib.recursiveUpdate base.options {
    userSettings.apps.dolphinEmu.package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = package;
      description = "Dolphin installé, avec la vibration des manettes DSU.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable { home.packages = [ package ]; })

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
