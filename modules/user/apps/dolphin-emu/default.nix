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

  # Client DSU (le téléphone comme Wiimote, module wiimote). Vibration : le client DSU de Dolphin ne l'envoyait pas
  # au serveur ; le correctif lui ajoute une sortie « Motor » et le message « Rumble controller motor » (0x110002)
  # du protocole cemuhook. Jeu en cours (0x110003, non officiel) : son identifiant et, pour Mario Kart Wii, l'étape
  # de la course, lue dans sa mémoire ; la manette affiche les boutons qui vont avec. Dolphin est donc compilé ici,
  # hors du cache. Un bump touchant ces fichiers fait échouer le build : refaire le patch sur les nouvelles sources.
  package = myLib.packaging.mkGuardedPatch {
    package = cfg.pkgs.dolphin-emu;
    patch = ./dsu-client.patch;
    files = {
      "Source/Core/InputCommon/ControllerInterface/DualShockUDPClient/DualShockUDPClient.cpp" =
        "1991a1714891ee47dc9b208f320976562ce6bc1e6c49943210c5c2114a5ea051";
      "Source/Core/InputCommon/ControllerInterface/DualShockUDPClient/DualShockUDPProto.h" =
        "b775d2586d19fff6a10ab00118e224caeed0c2e25da37aabcc19994538edd420";
    };
    where = "modules/user/apps/dolphin-emu/default.nix";
  };

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
      description = "Dolphin installé, avec la vibration des manettes DSU et le jeu en cours.";
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
