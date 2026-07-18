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

  # Attrset brut d'un thème (couleurs base16 + métadonnées). Le slug base16
  # est injecté depuis le nom du fichier (source unique) : sans lui,
  # base16.nix nomme tous les artefacts générés « untitled »
  # (base16-untitled.conf, untitled-gnome-shell-theme, ...).
  #
  # Les couleurs baseXX sont censées être du hex NU (sans #) : les
  # consommateurs (rofi, firefox, waybar...) préfixent eux-mêmes avec
  # "#${c.baseXX}". Un fichier de scheme qui inclut le # par erreur produirait
  # un "##" silencieux — on le retire donc systématiquement ici plutôt que de
  # compter sur chaque fichier pour rester bien formé.
  load =
    name:
    let
      raw = import (./schemes + "/${name}.nix");
      stripHash = v: if lib.isString v && lib.hasPrefix "#" v then lib.removePrefix "#" v else v;
    in
    lib.mapAttrs (k: v: if lib.hasPrefix "base" k then stripHash v else v) raw // { slug = name; };

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
      # Sans `wallpaper` ni `polarity` : ils ne concernent pas le scheme
      # base16 (polarity est déjà passé à part ci-dessus) et finiraient sinon
      # dans le yaml généré par stylix.
      base16Scheme = builtins.removeAttrs t [
        "wallpaper"
        "polarity"
      ];
    }
    // lib.optionalAttrs (chosen != null) {
      image = wallpaperPath pkgs chosen;
    };
}
