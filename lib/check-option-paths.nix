# Vérifie la convention centrale du dépôt : un module rangé dans
# modules/<arbre>/<a>/<b>/ déclare ses options sous <namespace>.<a>.<b>, les
# tirets du dossier devenant du camelCase (vercel-cli -> vercelCli).
#
# Pourquoi un check et pas juste de la discipline : un chemin d'option erroné
# ne casse RIEN de visible. L'option orpheline est simplement ignorée, et les
# lecteurs tolérants (`bindIf`, `clickIf`, qui font `attrByPath … false`)
# retombent silencieusement sur false — on perd un bind clavier ou un clic
# waybar sans le moindre message. C'est typiquement ce qu'un déplacement de
# dossier introduit.
#
# Deux fonctions parce que les deux arbres ne s'introspectent pas pareil :
#
#   byDeclarations — la bonne méthode. Part des options DÉCLARÉES et remonte
#     au fichier qui les déclare (attribut `declarations` du module system).
#     Exige seulement que le dossier soit un préfixe du chemin d'option, donc
#     un module peut déclarer des sous-options plus profondes que lui
#     (waybar/scripts.nix -> …waybar.scriptDir) et un dossier peut n'avoir
#     aucune option (boot, locale, network… sont inconditionnels).
#     Utilisable côté NixOS, où `options` est exposé par nixosSystem.
#
#   byDirectory — le repli pour home-manager, dont les options par user ne
#     sont pas atteignables par introspection (elles viennent d'un `imports`
#     dans le sous-module, pas de son type). Part des DOSSIERS et vérifie que
#     le chemin correspondant existe. Corollaire : sous modules/user, tout
#     dossier de module doit avoir une option — d'où la liste d'exceptions.
lib:

let
  kebabToCamel =
    name:
    let
      parts = lib.splitString "-" name;
    in
    lib.concatStrings (
      lib.imap0 (
        i: p: if i == 0 then p else lib.toUpper (lib.substring 0 1 p) + lib.substring 1 (-1) p
      ) parts
    );

  renderPath = segments: lib.concatStringsSep "." segments;
in
{
  byDeclarations =
    {
      # Attrset d'options à parcourir (ex. nixosConfigurations.X.options.systemSettings).
      options,
      # Nom du namespace, pour les messages (ex. "systemSettings").
      namespace,
      # Sous-dossier de modules/ concerné (ex. "system").
      tree,
      # Segments de dossier qui REGROUPENT sans nommer un niveau d'option.
      #
      # `modules/system/server/authelia/` déclare `systemSettings.authelia.*`, et
      # c'est voulu : `server/` dit « ces modules servent le rôle serveur », pas
      # « ces options vivent sous systemSettings.server ». Le rôle est déjà porté
      # par le profil qui les active ; le répéter dans chaque chemin d'option
      # allongerait tout sans rien distinguer, et rendrait le déplacement d'un
      # module vers/depuis ce dossier cassant pour toutes ses options.
      #
      # Sans cette liste le contrôle rejetait les soixante-cinq options du
      # dossier, donc échouait en permanence — et un contrôle qui échoue toujours
      # ne contrôle plus rien, il apprend seulement à ignorer sa sortie.
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

      # ".../modules/system/window-manager/sway/default.nix" -> [ "windowManager" "sway" ]
      # null pour un fichier hors de l'arbre (option redéclarée ailleurs).
      #
      # Les segments de `transparentDirs` sont retirés du chemin attendu : ils
      # rangent des modules sans nommer un niveau d'option.
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
      # userSettings évalué d'un user quelconque : les `options` sont
      # déclarées HORS des `mkIf`, elles existent donc même module coupé.
      userSettings,
      # Racine à parcourir (./modules/user).
      root,
      # Dossiers sans option propre. Chemin relatif à `root`, tirets d'origine.
      exceptions ? [ ],
    }:
    let
      # Dossiers contenant un default.nix = modules. Les autres (sway-config/,
      # vim-config/, scripts/, skills/commit/…) sont des données, ignorées.
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
