# API du dossier des thèmes, partagée par modules/system/stylix et
# modules/user/stylix (seuls consommateurs) :
#   themes = import ../../themes lib;
# Un thème = un fichier schemes/<nom>.nix (attrset pur : scheme base16 +
# polarity + wallpaper), auto-découvert comme les devshells — un nouveau
# fichier = un nouveau nom valide dans l'enum, rien à déclarer.
#
# NB : pas un module NixOS (fonction lib: ...) — ce dossier est hors du
# périmètre de lib/import-all.nix, qui ne parcourt que modules/system et
# modules/user.
lib: rec {
  # Noms des thèmes disponibles (pour lib.types.enum : une typo dans un
  # profil casse l'éval immédiatement).
  names = builtins.filter (x: x != null) (
    lib.mapAttrsToList (
      name: type:
      if type == "regular" && lib.hasSuffix ".nix" name then lib.removeSuffix ".nix" name else null
    ) (builtins.readDir ./schemes)
  );

  # Attrset brut d'un thème (couleurs base16 + métadonnées).
  load = name: import (./schemes + "/${name}.nix");

  # Registre des fonds d'écran (nom → source), découplé des thèmes : chaque
  # schéma référence son fond PAR DÉFAUT via `wallpaper = "<nom>"`, et un
  # profil/user peut en imposer un autre sans toucher au thème.
  wallpapers = import ./wallpapers.nix;
  wallpaperNames = builtins.attrNames wallpapers;

  # Nom du registre → chemin de l'image (fichier local du repo, ou fetchurl
  # pour les fonds distants).
  wallpaperPath =
    pkgs: name:
    let
      w = wallpapers.${name};
    in
    w.path or (pkgs.fetchurl w);

  # Bloc commun à poser dans `stylix = { ... }` : scheme, polarité, wallpaper.
  #   theme     : nom du thème (cf. names)
  #   wallpaper : surcharge optionnelle (nom du registre) ; null = le fond
  #               par défaut du thème. Un thème sans `wallpaper` reste
  #               utilisable (stylix sait vivre sans image).
  stylixSettings =
    {
      pkgs,
      theme,
      wallpaper ? null,
    }:
    let
      t = load theme;
      chosen = if wallpaper != null then wallpaper else t.wallpaper or null;
    in
    {
      inherit (t) polarity;
      # Sans la clé `wallpaper` : elle ne concerne pas le scheme base16 et
      # finirait sinon dans le yaml généré par stylix.
      base16Scheme = builtins.removeAttrs t [ "wallpaper" ];
    }
    // lib.optionalAttrs (chosen != null) {
      image = wallpaperPath pkgs chosen;
    };
}
