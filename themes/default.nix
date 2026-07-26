# API des thèmes, injectée dans TOUS les modules sous le nom `themes`
# (specialArgs / extraSpecialArgs, cf. flake.nix) — comme `myLib`, pour que
# personne n'ait à remonter jusqu'ici par des `../..` dépendants de sa
# profondeur.
#
# Les schemes amont (tinted-theming/schemes) ne sont pas vendorés, lus depuis
# l'input `tinted-schemes`. schemes/ ne contient que les nôtres (originaux,
# ou homonymes d'un thème amont dont on veut des couleurs différentes).
#
# Résolution d'un nom (cf. pathByName) : schemes/<nom>.yaml en priorité
# absolue, puis <tinted-schemes>/base16/<nom>.yaml, puis base24/<nom>.yaml
# (suffixé -base24 si le nom est déjà pris en base16, 43 collisions upstream).
#
# NB : pas un module NixOS — vit hors de modules/, hors du périmètre de
# lib/import-all.nix.
lib: inputs:

let
  self = rec {
    localDir = ./schemes;
    upstream = inputs.tinted-schemes;

    # Le parseur stylix (fromYaml, sans IFD) échoue sur les commentaires en fin
    # de ligne et les `description: |` multi-lignes (4 fichiers amont sur 495).
    # Format assez régulier pour qu'un `builtins.match` par ligne suffise —
    # vérifié identique à PyYAML sur les 513 fichiers.
    parseScheme =
      name:
      let
        path = pathByName.${name};
        lines = lib.splitString "\n" (builtins.readFile path);

        # `  base0A: "#ffbb08"  # yellow` -> [ "base0A" "ffbb08" ] ; # et guillemets optionnels.
        colorMatch =
          l: builtins.match "[[:space:]]*(base[0-9A-Fa-f]{2}):[[:space:]]*\"?#?([0-9a-fA-F]{6})\"?.*" l;

        colors = lib.listToAttrs (
          lib.concatMap (
            l:
            let
              m = colorMatch l;
            in
            lib.optional (m != null) (lib.nameValuePair (builtins.head m) (lib.toLower (builtins.elemAt m 1)))
          ) lines
        );

        # Champ scalaire de premier niveau, guillemets optionnels.
        field =
          key:
          let
            hit = lib.findFirst (l: builtins.match "${key}:.*" l != null) null lines;
            m =
              if hit == null then
                null
              else
                builtins.match "${key}:[[:space:]]*\"?([^\"]*[^\"[:space:]])\"?[[:space:]]*" hit;
          in
          if m == null then null else builtins.head m;
      in
      lib.throwIf (colors == { }) "themes : aucune couleur lue dans ${toString path}" (
        colors
        // {
          # Nomme les fichiers générés par stylix (base16-<slug>.conf).
          slug = name;
          scheme = if field "name" != null then field "name" else name;
        }
        // lib.optionalAttrs (field "author" != null) { author = field "author"; }
        // lib.optionalAttrs (field "variant" != null) { variant = field "variant"; }
      );

    # .yml toléré en plus de .yaml (cyberpunk.yml en amont).
    yamlNames =
      dir:
      builtins.filter (x: x != null) (
        lib.mapAttrsToList (
          name: type:
          if type == "regular" && (lib.hasSuffix ".yaml" name || lib.hasSuffix ".yml" name) then
            lib.removeSuffix ".yml" (lib.removeSuffix ".yaml" name)
          else
            null
        ) (builtins.readDir dir)
      );

    yamlPath =
      dir: name:
      let
        yaml = dir + "/${name}.yaml";
      in
      if builtins.pathExists yaml then yaml else dir + "/${name}.yml";

    localNames = yamlNames localDir;
    base16Names = yamlNames (upstream + "/base16");
    base24Names = yamlNames (upstream + "/base24");

    # Un base24 homonyme est suffixé plutôt que d'écraser silencieusement.
    claimedNames = localNames ++ base16Names;

    # Source unique des noms publics, lue telle quelle par la galerie.
    pathByName =
      (lib.genAttrs localNames (n: yamlPath localDir n))
      // (lib.genAttrs (lib.subtractLists localNames base16Names) (n: yamlPath (upstream + "/base16") n))
      // (lib.listToAttrs (
        map (
          n:
          lib.nameValuePair (if builtins.elem n claimedNames then "${n}-base24" else n) (
            yamlPath (upstream + "/base24") n
          )
        ) base24Names
      ));

    names = builtins.attrNames pathByName; # pour lib.types.enum : typo -> éval cassée

    polarity = name: (parseScheme name).variant or "dark"; # défaut de la spec

    # Écrit par la galerie ; purement indicatif, aucun rebuild au changement.
    favorites = builtins.fromJSON (builtins.readFile ./gallery/favorites.json);

    meta = import ./wallpapers.nix;
    wallpapers = meta.registry;
    wallpaperNames = builtins.attrNames wallpapers;

    wallpaperPath =
      pkgs: name:
      let
        w = wallpapers.${name};
      in
      w.path or (pkgs.fetchurl w);

    # Bloc commun à poser dans `stylix = { ... }`. wallpaper = surcharge
    # explicite ; null = résolution automatique (cf. `chosen`).
    stylixSettings =
      {
        pkgs,
        theme,
        wallpaper ? null,
      }:
      let
        themePolarity = polarity theme;
        # Surcharge explicite > fond du thème > défaut de la polarité (garantit
        # une image même hors des ~60 thèmes couverts par themeWallpaper).
        chosen =
          if wallpaper != null then
            wallpaper
          else
            meta.themeWallpaper.${theme} or meta.defaultWallpaper.${themePolarity} or null;
      in
      {
        polarity = themePolarity;
        base16Scheme = parseScheme theme;
      }
      // lib.optionalAttrs (chosen != null) {
        image = wallpaperPath pkgs chosen;
      };

    # ./fonts.nix et ./gallery prennent un `pkgs` : exposés en fonctions
    # plutôt qu'en chemins, seul ce fichier connaît encore sa propre structure.
    fontsFor = import ./fonts.nix;
    galleryFor =
      pkgs:
      import ./gallery {
        inherit pkgs;
        themes = self;
      };
  };
in
self
