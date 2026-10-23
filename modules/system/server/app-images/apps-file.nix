{
  config,
  lib,
  ...
}:

# Les apps décrites en données (`apps.json`), le format qu'écrivent le dashboard et `apps.yml`.
# Chaque entrée devient une `systemSettings.apps.<nom>` ; du Nix peut compléter la même app
# (réglages hors du format, comme un healthcheck), jamais remplacer ce que dit le JSON.
#
# Une entrée peut avoir des environnements (`environments.<id>`) : le même site sur une autre
# branche, servi comme une app à part, `<site>-<id>`. Un environnement hérite de son parent
# (`from`, la racine par défaut) chaque section qu'il ne règle pas lui-même ; une section est
# à lui dès que sa clé repère est là : `expose` (accès), `containers`, `internetAccess` (options).
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

  fail = where: msg: throw "${toString file} : ${where} : ${msg}";

  accessKeys = [
    "expose"
    "devices"
    "sso"
  ];

  containersKeys = [
    "containers"
    "entrypoint"
  ];

  optionKeys = [
    "internetAccess"
    "probe"
    "rateLimit"
  ];

  rootKeys = [
    "name"
    "subdomain"
    "environments"
  ]
  ++ accessKeys
  ++ containersKeys
  ++ optionKeys;

  envKeys = [
    "name"
    "branch"
    "from"
    "data"
    "pin"
    "subdomain"
  ]
  ++ accessKeys
  ++ containersKeys
  ++ optionKeys;

  containerKeys = [
    "image"
    "memory"
    "dependsOn"
    "data"
    "secrets"
  ];

  pick = keys: attrs: lib.filterAttrs (k: _: lib.elem k keys) attrs;

  # Tag publié par app-image.yml pour une branche : `feat/charts` -> `feat-charts`.
  tagOf =
    branch:
    lib.concatStrings (
      map (ch: if builtins.match "[A-Za-z0-9._-]" ch != null then ch else "-") (
        lib.stringToCharacters branch
      )
    );

  # `myetf:main` -> `myetf` (le registre peut contenir un port, pas le dernier segment).
  untag =
    image:
    let
      parts = lib.splitString "/" image;
    in
    lib.concatStringsSep "/" (lib.init parts ++ [ (lib.head (lib.splitString ":" (lib.last parts))) ]);

  # Emplacement par défaut des données : un dossier par app et par conteneur.
  dataDir =
    app: container: path:
    "/var/lib/apps/${app}/${container}${path}";

  # Les déploiements d'un site : la racine (`id = null`, l'app porte le nom du site), puis
  # chaque environnement (`<site>-<id>`).
  deploymentsOf =
    site: e0:
    let
      e = only rootKeys site e0;

      envs = lib.mapAttrs (
        id: v0:
        let
          where = "${site}.environments.${id}";
          v = only envKeys where v0;
        in
        if builtins.match "[a-z][a-z0-9-]{0,15}" id == null then
          fail where "identifiant invalide (minuscules, chiffres et tirets, 16 caractères au plus)"
        else if !(v ? branch) || builtins.match "[A-Za-z0-9][A-Za-z0-9._/-]{0,99}" v.branch == null then
          fail where "`branch` manquante ou invalide"
        else if v ? pin && builtins.match "sha-[0-9a-f]{7,40}" v.pin == null then
          fail where "`pin` : un tag sha-<commit>"
        else if
          !(lib.elem (v.data or "separate") [
            "separate"
            "copy"
            "shared"
          ])
        then
          fail where "`data` : separate, copy ou shared"
        else if !(v ? expose) && (v ? devices || v ? sso) then
          fail where "`devices` et `sso` vont avec `expose` (la section accès est à lui dès que `expose` est là)"
        else if !(v ? containers) && v ? entrypoint then
          fail where "`entrypoint` va avec `containers`"
        else if !(v ? internetAccess) && (v ? probe || v ? rateLimit) then
          fail where "`probe` et `rateLimit` vont avec `internetAccess` (la section options est à lui dès qu'il est là)"
        else
          v
      ) (e.environments or { });

      appOf = id: if id == null then site else "${site}-${id}";

      rootSections = {
        access = pick accessKeys e;
        containers = pick containersKeys e;
        options = pick optionKeys e;
      };

      # Sections effectives d'un environnement, en remontant les parents.
      sectionsOf =
        depth: id:
        if id == null then
          rootSections
        else if depth > 16 then
          fail site "boucle d'héritage entre environnements (`from`)"
        else
          let
            v = envs.${id} or (fail site "`from` désigne un environnement inconnu : ${id}");
            p = sectionsOf (depth + 1) (v.from or null);
          in
          {
            access = if v ? expose then pick accessKeys v else p.access;
            containers = if v ? containers then pick containersKeys v else p.containers;
            options = if v ? internetAccess then pick optionKeys v else p.options;
          };

      rootData =
        container: path:
        lib.findFirst (d: d.path == path) null ((e.containers.${container} or { }).data or [ ]);

      # Dossier hôte d'un chemin de données pour un environnement ; `shared` remonte au parent.
      sourceOf =
        depth: id: container: path:
        if id == null then
          let
            d = rootData container path;
          in
          if d != null && d ? on then
            {
              source = d.on;
              auto = false;
            }
          else
            {
              source = dataDir site container path;
              auto = true;
            }
        else if depth > 16 then
          fail site "boucle d'héritage entre environnements (`from`)"
        else if (envs.${id}.data or "separate") == "shared" then
          sourceOf (depth + 1) (envs.${id}.from or null) container path
        else
          {
            source = dataDir (appOf id) container path;
            auto = true;
          };

      deployment =
        id:
        let
          v = if id == null then e else envs.${id};
          s = sectionsOf 0 id;
          app = appOf id;
          ownContainers = id == null || v ? containers;
          tag = v.pin or (tagOf v.branch);
          mode = if id == null then "separate" else v.data or "separate";

          containerOf =
            name: c0:
            let
              where = "${app}.containers.${name}";
              c = only containerKeys where c0;
              hasTag = lib.hasInfix ":" (lib.last (lib.splitString "/" c.image));
            in
            if id != null && ownContainers && hasTag then
              fail where "dans un environnement, l'image se donne sans tag (il vient de `branch` ou `pin`)"
            else
              {
                inherit name;
                image = if id == null then c.image else "${untag c.image}:${tag}";
                memory = c.memory or null;
                dependsOn = c.dependsOn or [ ];
                secrets = c.secrets or [ ];
                data = map (
                  d0:
                  let
                    d = only [ "path" "on" ] "${where}.data" d0;
                    own = sourceOf 0 id name d.path;
                  in
                  if id != null && ownContainers && d ? on then
                    fail where "`data.on` n'est permis qu'à la racine du site"
                  else
                    {
                      inherit (d) path;
                      inherit (own) source auto;
                      # Copie : le dossier du parent, recopié au premier démarrage s'il manque.
                      copyFrom = if mode == "copy" then (sourceOf 0 (v.from or null) name d.path).source else null;
                    }
                ) (c.data or [ ]);
              };
        in
        {
          inherit site id app;
          child = id != null;
          name = v.name or (if id == null then "production" else id);
          copy = mode == "copy";
          inherit (s) access options;
          subdomain = if id == null then e.subdomain or null else v.subdomain or app;
          entrypoint = s.containers.entrypoint or null;
          containers = lib.mapAttrsToList containerOf (
            s.containers.containers or (fail app "aucun conteneur (`containers`)")
          );
        };
    in
    map deployment ([ null ] ++ lib.attrNames envs);

  deployments = lib.concatLists (lib.mapAttrsToList deploymentsOf entries);

  toApp =
    d:
    let
      expose = d.access.expose or "public";
    in
    {
      inherit expose;
      sso.enable = d.access.sso or false;
      internetAccess = d.options.internetAccess or false;
      # Une préversion publique n'a rien à faire dans les moteurs de recherche.
      noindex = d.child && expose == "public";
      containers = lib.listToAttrs (
        map (
          c:
          lib.nameValuePair c.name {
            inherit (c) image memory dependsOn;
            volumes = map (x: {
              inherit (x) source;
              target = x.path;
              readOnly = false;
              chown = x.auto;
            }) c.data;
            environmentFiles = map (k: config.sops.secrets.${k}.path) c.secrets;
          }
        ) d.containers
      );
    }
    // lib.optionalAttrs (d.subdomain != null) { inherit (d) subdomain; }
    // lib.optionalAttrs (d.access ? devices) { inherit (d.access) devices; }
    // lib.optionalAttrs (d.options ? probe) { probe.path = d.options.probe; }
    // lib.optionalAttrs (d.entrypoint != null) { inherit (d) entrypoint; }
    // lib.optionalAttrs (d.options ? rateLimit) {
      rateLimit = {
        enable = true;
        paths = d.options.rateLimit;
      };
    };

  containers = lib.concatMap (
    d:
    map (c: {
      inherit (d) site app;
      inherit c;
      unit = "podman-${d.app}-${c.name}";
    }) d.containers
  ) deployments;

  secretsUsed = lib.concatMap (
    x:
    map (key: {
      inherit (x) site unit;
      inherit key;
    }) x.c.secrets
  ) containers;

  appNames = map (d: d.app) deployments;
in
{
  options.systemSettings.appImages = {
    appsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "./apps.json";
      description = ''
        Apps décrites en données (format de docs/apps.md), modifiées par le dashboard et `apps.yml`.
        Chacune devient une entrée de `systemSettings.apps`, chaque environnement aussi.
      '';
    };

    copies = lib.mkOption {
      type = lib.types.attrsOf lib.types.raw;
      readOnly = true;
      internal = true;
      default = lib.listToAttrs (
        map (
          d:
          lib.nameValuePair d.app {
            units = map (c: "podman-${d.app}-${c.name}.service") d.containers;
            pairs = lib.concatMap (
              c:
              map (x: {
                from = x.copyFrom;
                to = x.source;
              }) (lib.filter (x: x.copyFrom != null && x.auto) c.data)
            ) d.containers;
          }
        ) (lib.filter (d: d.copy) deployments)
      );
      description = "Environnements en données « copie » : leurs unités et les dossiers à recopier depuis le parent.";
    };
  };

  config = lib.mkIf (file != null) {
    systemSettings.apps = lib.listToAttrs (map (d: lib.nameValuePair d.app (toApp d)) deployments);

    assertions = [
      {
        # `<site>-<env>` ne doit pas tomber sur un autre site (ou un autre environnement).
        assertion = lib.length (lib.unique appNames) == lib.length appNames;
        message = "${toString file} : deux déploiements portent le même nom : ${
          toString (lib.unique (lib.filter (n: lib.count (m: m == n) appNames > 1) appNames))
        } (un environnement s'appelle `<site>-<id>`).";
      }
      {
        # Un site ne reçoit que ses propres secrets : jamais le jeton du registre ou le webhook.
        assertion = lib.all (s: lib.hasPrefix "${s.site}/" s.key) secretsUsed;
        message = "${toString file} : un site ne peut recevoir que des secrets rangés sous son nom (`<site>/…`) : ${
          toString (
            map (s: "${s.site} → ${s.key}") (lib.filter (s: !lib.hasPrefix "${s.site}/" s.key) secretsUsed)
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
            || d.source == "/var/lib/${x.site}"
            || lib.hasPrefix "/var/lib/${x.site}/" d.source
            || lib.hasPrefix "${x.site}-" d.source
          ) x.c.data
        ) containers;
        message = "${toString file} : un `data.on` doit être /var/lib/<site>(/…) ou un volume podman nommé `<site>-…`.";
      }
    ];

    # Dossier créé à chaque démarrage ; `:U` le donne ensuite à l'utilisateur de l'image.
    # Pas de tmpfiles : il remettrait root comme propriétaire à chaque activation.
    # Données « copie » : au premier démarrage, le dossier du parent est recopié (propriétaire compris).
    systemd.services = lib.mkMerge (
      map (
        x:
        let
          auto = lib.filter (d: d.auto) x.c.data;
          copies = lib.filter (d: d.copyFrom != null) auto;
          dirs = map (d: d.source) auto;
        in
        lib.optionalAttrs (dirs != [ ]) {
          ${x.unit}.preStart = lib.mkBefore (
            lib.concatMapStrings (d: ''
              if [ ! -e ${lib.escapeShellArg d.source} ] && [ -e ${lib.escapeShellArg d.copyFrom} ]; then
                mkdir -p "$(dirname ${lib.escapeShellArg d.source})"
                cp -a ${lib.escapeShellArg d.copyFrom} ${lib.escapeShellArg d.source}
              fi
            '') copies
            + "mkdir -p ${lib.escapeShellArgs dirs}"
          );
        }
      ) containers
    );

    sops.secrets = lib.mkMerge (
      map (s: { ${s.key}.restartUnits = [ "${s.unit}.service" ]; }) secretsUsed
    );
  };
}
