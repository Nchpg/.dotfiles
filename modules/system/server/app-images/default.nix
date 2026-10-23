{
  config,
  lib,
  ...
}:

# Réglages communs aux images des apps : nom court, digest et port lus dans le lock, login du registre.
let
  cfg = config.systemSettings.appImages;

  lock = if cfg.lockFile == null then { } else lib.importJSON cfg.lockFile;

  # `portfolio:main` -> `ghcr.io/nchpg/portfolio:main` ; une référence @sha256 reste telle quelle.
  # update.sh ne recopie pas cette règle : il lit le résultat dans `wanted`.
  normalize =
    image:
    if lib.hasInfix "@" image then
      image
    else
      let
        withRepo =
          if lib.hasInfix "/" image then
            image
          else if cfg.registry != null then
            "${cfg.registry}/${image}"
          else
            throw "systemSettings.appImages.registry est requis pour le nom court « ${image} ».";
      in
      if lib.hasInfix ":" (lib.last (lib.splitString "/" withRepo)) then
        withRepo
      else
        throw "image « ${image} » sans tag : écris la branche suivie, par exemple « ${image}:main ».";

  entryOf =
    image:
    let
      ref = normalize image;
    in
    lock.${ref}
      or (throw "image ${ref} absente de ${toString cfg.lockFile} : `dots update apps` l'y ajoute (ou donne une référence @sha256 complète).");

  # Le tag est retiré : certaines versions de podman refusent une référence qui porte tag et digest.
  withoutTag =
    ref:
    let
      parts = lib.splitString "/" ref;
    in
    lib.concatStringsSep "/" (lib.init parts ++ [ (lib.head (lib.splitString ":" (lib.last parts))) ]);
in
{
  options.systemSettings.appImages = {
    lockFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "./apps.lock.json";
      description = ''
        Lock des images : digest et port exposé de chaque référence, tenu à jour par
        la CI des apps et `dots update apps` (cf. docs/apps.md).
      '';
    };

    registry = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "ghcr.io/moi";
      description = "Préfixe d'une image donnée par son seul nom (`portfolio:main`).";
    };

    login = lib.mkOption {
      default = null;
      description = ''
        Identifiants pour les images de `registry` (packages privés). Un échec de
        connexion ne coupe pas une app qui tourne : podman reprend l'image locale.
      '';
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            username = lib.mkOption {
              type = lib.types.str;
              example = "moi";
              description = "Compte du registre.";
            };

            passwordKey = lib.mkOption {
              type = lib.types.str;
              example = "ghcr/token";
              description = "Clé sops du jeton (portée read:packages).";
            };
          };
        }
      );
    };

    wanted = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      internal = true;
      default = lib.unique (
        lib.filter (r: !lib.hasInfix "@" r) (
          lib.concatMap (app: map (c: normalize c.image) (lib.attrValues app.containers)) (
            lib.attrValues config.systemSettings.apps
          )
        )
      );
      description = "Références à épingler, lues par `dots update apps` pour compléter le lock.";
    };

    helpers = lib.mkOption {
      type = lib.types.attrsOf lib.types.raw;
      readOnly = true;
      internal = true;
      default = {
        ref = normalize;

        # `ghcr.io/moi/app:main` -> `ghcr.io/moi/app`.
        untag = withoutTag;

        # Image suivie par le lock et publiée sous `registry` : celles que think surveille.
        own =
          image:
          !lib.hasInfix "@" image
          && cfg.registry != null
          && lib.hasPrefix "${cfg.registry}/" (normalize image);

        entry = image: if lib.hasInfix "@" image then null else entryOf image;

        image =
          image:
          if lib.hasInfix "@" image then
            image
          else
            "${withoutTag (normalize image)}@${(entryOf image).digest}";

        port = image: if lib.hasInfix "@" image then null else (entryOf image).port or null;

        login =
          image:
          if
            cfg.login != null && cfg.registry != null && lib.hasPrefix "${cfg.registry}/" (normalize image)
          then
            cfg.login
          else
            null;
      };
      description = "Résolution d'une image déclarée : référence épinglée, port exposé, login.";
    };
  };
}
