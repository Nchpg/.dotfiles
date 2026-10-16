lib:

let
  inherit (import ../modules/option-path.nix lib) kebabToCamel;

  renderPath = segments: lib.concatStringsSep "." segments;
in
{
  byDeclarations =
    {
      options,
      namespace,
      tree,
      # Dossiers sans niveau d'option : server/authelia/ déclare `systemSettings.authelia.*`.
      transparentDirs ? [ ],
    }:
    let
      leaves =
        path: o:
        if lib.isOption o then
          [
            {
              inherit path;
              inherit (o) declarations;
            }
          ]
        else if lib.isAttrs o then
          lib.concatLists (lib.mapAttrsToList (n: v: leaves (path ++ [ n ]) v) o)
        else
          [ ];

      # null hors de l'arbre.
      dirOf =
        file:
        let
          m = builtins.match ".*/modules/${tree}/(.*)/[^/]*[.]nix" (toString file);
        in
        if m == null then
          null
        else
          lib.filter (s: !(lib.elem s transparentDirs)) (
            map kebabToCamel (lib.splitString "/" (builtins.head m))
          );

      wrong = lib.unique (
        lib.concatMap (
          leaf:
          lib.concatMap (
            decl:
            let
              dir = dirOf decl;
            in
            lib.optional (dir != null && lib.take (lib.length dir) leaf.path != dir)
              "${namespace}.${renderPath leaf.path} declaree dans modules/${tree}/${lib.concatStringsSep "/" dir}/"
          ) leaf.declarations
        ) (leaves [ ] options)
      );
    in
    {
      ok = wrong == [ ];
      report =
        if wrong == [ ] then
          "option-paths (${tree}) : toutes les options declarees correspondent a leur dossier."
        else
          ''
            option-paths (${tree}) : ces options ne sont pas declarees dans le dossier
            correspondant a leur chemin. Corrige le chemin d'option ou deplace le module.

            ${lib.concatStringsSep "\n            " wrong}
          '';
    };

  byDirectory =
    {
      userSettings,
      root,
      exceptions ? [ ],
    }:
    let
      moduleDirs =
        prefix: dir:
        lib.concatLists (
          lib.mapAttrsToList (
            name: type:
            let
              rel = prefix ++ [ name ];
              sub = dir + "/${name}";
            in
            lib.optionals (type == "directory") (
              lib.optional (builtins.pathExists (sub + "/default.nix")) rel ++ moduleDirs rel sub
            )
          ) (builtins.readDir dir)
        );

      found = moduleDirs [ ] root;

      missing = lib.filter (
        segments:
        !(lib.elem (lib.concatStringsSep "/" segments) exceptions)
        && !(lib.hasAttrByPath (map kebabToCamel segments) userSettings)
      ) found;

      render =
        segments:
        "modules/user/${lib.concatStringsSep "/" segments} -> userSettings.${renderPath (map kebabToCamel segments)}";
    in
    {
      ok = missing == [ ];
      report =
        if missing == [ ] then
          "option-paths (user) : ${toString (lib.length found)} modules, tous alignes sur leur dossier."
        else
          ''
            option-paths (user) : ces modules ne declarent pas l'option correspondant
            a leur dossier. Corrige le chemin d'option, deplace le module, ou ajoute-le
            aux exceptions (flake.nix, checks.option-paths) si l'ecart est volontaire.

            ${lib.concatMapStringsSep "\n            " render missing}
          '';
    };
}
