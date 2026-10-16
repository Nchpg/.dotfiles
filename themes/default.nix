lib: inputs:

let
  self = rec {
    localDir = ./schemes;
    upstream = inputs.tinted-schemes;

    # Le parseur stylix (fromYaml) échoue sur certains fichiers amont : match par ligne.
    parseScheme =
      name:
      let
        path = pathByName.${name};
        lines = lib.splitString "\n" (builtins.readFile path);

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

        schemeName = field "name";
        author = field "author";
        variant = field "variant";
      in
      lib.throwIf (colors == { }) "themes : aucune couleur lue dans ${toString path}" (
        colors
        // {
          slug = name;
          scheme = if schemeName != null then schemeName else name;
        }
        // lib.optionalAttrs (author != null) { inherit author; }
        // lib.optionalAttrs (variant != null) { inherit variant; }
      );

    # .yml toléré (cyberpunk.yml en amont).
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

    names = builtins.attrNames pathByName;

    polarity = name: polarityOf (parseScheme name);
    polarityOf = scheme: scheme.variant or "dark";

    meta = import ./wallpapers.nix;
    wallpapers = meta.registry;
    wallpaperNames = builtins.attrNames wallpapers;

    wallpaperPath =
      pkgs: name:
      let
        w = wallpapers.${name};
      in
      w.path or (pkgs.fetchurl w);

    stylixSettings =
      {
        pkgs,
        theme,
        wallpaper ? null,
      }:
      let
        scheme = parseScheme theme;
        themePolarity = polarityOf scheme;
        chosen =
          if wallpaper != null then
            wallpaper
          else
            meta.themeWallpaper.${theme} or meta.defaultWallpaper.${themePolarity} or null;
      in
      {
        polarity = themePolarity;
        base16Scheme = scheme;
      }
      // lib.optionalAttrs (chosen != null) {
        image = wallpaperPath pkgs chosen;
      };

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
