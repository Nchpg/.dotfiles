# API du dossier des thèmes, partagée par modules/system/stylix,
# modules/user/stylix et flake.nix :
#   themes = import ../../themes lib inputs;
#
# Les schemes amont (tinted-theming/schemes) ne sont PAS vendorés : ils sont
# lus depuis l'input `tinted-schemes`. schemes/ ne contient que les nôtres —
# originaux, ou homonymes d'un thème amont dont on veut des couleurs
# différentes (ex. dracula : palette officielle plutôt que l'adaptation
# base16). Les parcourir avec un aperçu : commande `theme` sans argument.
#
# Résolution d'un nom vers son fichier (cf. pathByName) :
#   1. schemes/<nom>.yaml — priorité absolue, masque l'amont.
#   2. <tinted-schemes>/base16/<nom>.yaml
#   3. <tinted-schemes>/base24/<nom>.yaml, sous <nom> si libre, sinon sous
#      <nom>-base24 : 43 noms existent dans les deux specs avec des couleurs
#      différentes, les deux doivent rester accessibles.
#
# NB : pas un module NixOS (fonction lib: inputs: ...) — ce dossier est hors
# du périmètre de lib/import-all.nix, qui ne parcourt que modules/system et
# modules/user.
lib: inputs: rec {
  localDir = ./schemes;
  upstream = inputs.tinted-schemes;

  # Parse un scheme yaml en Nix pur, pour le passer à `stylix.base16Scheme`
  # sous forme d'attrset — que mkSchemeAttrs accepte et prend tel quel.
  #
  # Le parseur de stylix (base16.nix/fromYaml, sans IFD) échoue sinon sur les
  # commentaires en fin de ligne et les `description: |` multi-lignes : 4
  # fichiers amont sur 495, qu'il fallait exclure de l'enum. Sa propre doc
  # reconnaît la limite (« does weird things with some documents »).
  #
  # Le format amont est assez régulier pour qu'un `builtins.match` par ligne
  # suffise — vérifié identique à PyYAML sur les 513 fichiers.
  parseScheme =
    name:
    let
      path = pathByName.${name};
      lines = lib.splitString "\n" (builtins.readFile path);

      # `  base0A: "#ffbb08"  # yellow` -> [ "base0A" "ffbb08" ]
      # Le # du hex et les guillemets sont optionnels : les deux formes existent.
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
    lib.throwIf (colors == { }) "modules/themes : aucune couleur lue dans ${toString path}" (
      colors
      // {
        # slug : nomme les fichiers générés par stylix (base16-<slug>.conf).
        # Sans lui, tout s'appellerait « untitled ».
        slug = name;
        scheme = if field "name" != null then field "name" else name;
      }
      // lib.optionalAttrs (field "author" != null) { author = field "author"; }
      // lib.optionalAttrs (field "variant" != null) { variant = field "variant"; }
    );

  # .yml toléré en plus de .yaml : l'amont contient un cyberpunk.yml.
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

  # Noms déjà pris : un base24 homonyme est suffixé plutôt que d'en écraser
  # un silencieusement.
  claimedNames = localNames ++ base16Names;

  # Source unique des noms publics : `names` en dérive, et la galerie lit le
  # même attrset — aucun nom n'est reconstruit par manipulation de chaîne.
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

  # Pour lib.types.enum : une typo dans un profil casse l'éval immédiatement.
  names = builtins.attrNames pathByName;

  # Repli sur "dark" : quelques schemes amont anciens ne déclarent pas
  # `variant`, et c'est la valeur par défaut de la spec.
  polarity = name: (parseScheme name).variant or "dark";

  # Écrit par la galerie. Purement indicatif : rien dans la config construite
  # n'en dépend, donc changer un favori ne demande aucun rebuild.
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

  # Bloc commun à poser dans `stylix = { ... }`.
  #   wallpaper : surcharge optionnelle ; null = le fond par défaut du thème,
  #               qui peut lui-même être absent (stylix vit sans image).
  stylixSettings =
    {
      pkgs,
      theme,
      wallpaper ? null,
    }:
    let
      chosen = if wallpaper != null then wallpaper else meta.themeWallpaper.${theme} or null;
    in
    {
      polarity = polarity theme;
      base16Scheme = parseScheme theme;
    }
    // lib.optionalAttrs (chosen != null) {
      image = wallpaperPath pkgs chosen;
    };
}
