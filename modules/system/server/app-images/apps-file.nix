{
  config,
  lib,
  ...
}:

# Les apps décrites en données (`apps.json`), le format qu'écrivent le dashboard et `apps.yml`.
# Chaque entrée devient une `systemSettings.apps.<nom>` ; du Nix peut compléter la même app
# (réglages hors du format, comme un healthcheck), jamais remplacer ce que dit le JSON.
let
  file = config.systemSettings.appImages.appsFile;

  entries = if file == null then { } else lib.importJSON file;

  # Une clé inconnue est une faute de frappe : mieux vaut refuser l'évaluation que l'ignorer.
  only =
    keys: where: attrs:
    let
      extra = lib.subtractLists keys (lib.attrNames attrs);
    in
    if extra == [ ] then
      attrs
    else
      throw "${toString file} : ${where} : clé(s) inconnue(s) ${toString extra} (permises : ${toString keys}).";

  appKeys = [
    "subdomain"
    "expose"
    "devices"
    "sso"
    "internetAccess"
    "probe"
    "entrypoint"
    "rateLimit"
    "containers"
  ];

  containerKeys = [
    "image"
    "memory"
    "dependsOn"
    "data"
    "secrets"
  ];

  # Emplacement par défaut des données : un dossier par app et par conteneur.
  dataDir =
    app: container: path:
    "/var/lib/apps/${app}/${container}${path}";

  dataOf =
    app: container: c:
    map (
      d0:
      let
        d = only [ "path" "on" ] "${app}.containers.${container}.data" d0;
      in
      {
        inherit (d) path;
        source = d.on or (dataDir app container d.path);
        # Emplacement choisi à la main : il garde ses droits tels quels.
        auto = !(d ? on);
      }
    ) (c.data or [ ]);

  toContainer =
    app: name: c0:
    let
      c = only containerKeys "${app}.containers.${name}" c0;
    in
    {
      inherit (c) image;
      memory = c.memory or null;
      dependsOn = c.dependsOn or [ ];
      volumes = map (d: {
        inherit (d) source;
        target = d.path;
        readOnly = false;
        chown = d.auto;
      }) (dataOf app name c);
      environmentFiles = map (k: config.sops.secrets.${k}.path) (c.secrets or [ ]);
    };

  toApp =
    name: e0:
    let
      e = only appKeys name e0;
    in
    {
      expose = e.expose or "public";
      sso.enable = e.sso or false;
      internetAccess = e.internetAccess or false;
      containers = lib.mapAttrs (toContainer name) e.containers;
    }
    // lib.optionalAttrs (e ? subdomain) { inherit (e) subdomain; }
    // lib.optionalAttrs (e ? devices) { inherit (e) devices; }
    // lib.optionalAttrs (e ? probe) { probe.path = e.probe; }
    // lib.optionalAttrs (e ? entrypoint) { inherit (e) entrypoint; }
    // lib.optionalAttrs (e ? rateLimit) {
      rateLimit = {
        enable = true;
        paths = e.rateLimit;
      };
    };

  containers = lib.concatLists (
    lib.mapAttrsToList (
      app: e:
      lib.mapAttrsToList (name: c: {
        inherit app name c;
        unit = "podman-${app}-${name}";
      }) (e.containers or { })
    ) entries
  );

  secretsUsed = lib.concatMap (
    x:
    map (key: {
      inherit (x) app unit;
      inherit key;
    }) (x.c.secrets or [ ])
  ) containers;
in
{
  options.systemSettings.appImages.appsFile = lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    default = null;
    example = lib.literalExpression "./apps.json";
    description = ''
      Apps décrites en données (format de docs/apps.md), modifiées par le dashboard et `apps.yml`.
      Chacune devient une entrée de `systemSettings.apps`.
    '';
  };

  config = lib.mkIf (file != null) {
    systemSettings.apps = lib.mapAttrs toApp entries;

    assertions = [
      {
        # Un site ne reçoit que ses propres secrets : jamais le jeton du registre ou le webhook.
        assertion = lib.all (s: lib.hasPrefix "${s.app}/" s.key) secretsUsed;
        message = "${toString file} : un site ne peut recevoir que des secrets rangés sous son nom (`<site>/…`) : ${
          toString (
            map (s: "${s.app} → ${s.key}") (lib.filter (s: !lib.hasPrefix "${s.app}/" s.key) secretsUsed)
          )
        }.";
      }
      {
        # Un emplacement choisi à la main reste dans le domaine du site : son dossier, ou un volume à son nom.
        assertion = lib.all (
          x:
          lib.all (
            d:
            d.auto
            || d.source == "/var/lib/${x.app}"
            || lib.hasPrefix "/var/lib/${x.app}/" d.source
            || lib.hasPrefix "${x.app}-" d.source
          ) (dataOf x.app x.name x.c)
        ) containers;
        message = "${toString file} : un `data.on` doit être /var/lib/<site>(/…) ou un volume podman nommé `<site>-…`.";
      }
    ];

    # Dossier créé à chaque démarrage ; `:U` le donne ensuite à l'utilisateur de l'image.
    # Pas de tmpfiles : il remettrait root comme propriétaire à chaque activation.
    systemd.services = lib.mkMerge (
      map (
        x:
        let
          dirs = map (d: d.source) (lib.filter (d: d.auto) (dataOf x.app x.name x.c));
        in
        lib.optionalAttrs (dirs != [ ]) {
          ${x.unit}.preStart = lib.mkBefore "mkdir -p ${lib.escapeShellArgs dirs}";
        }
      ) containers
    );

    sops.secrets = lib.mkMerge (
      map (s: { ${s.key}.restartUnits = [ "${s.unit}.service" ]; }) secretsUsed
    );
  };
}
