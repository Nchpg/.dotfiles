{
  config,
  options,
  lib,
  inputs,
  ...
}:

# Onglet Mises à jour : les versions de ce qui tourne, découvertes dans la config et jamais listées à
# la main. Tout service activé qui a un paquet (`services.<x>`, ses `instances` comprises, et
# `virtualisation.<x>`), puis le noyau et systemd ; chacun avec l'entrée du flake qui le fournit. La génération active le garde dans
# /etc/dotfiles/inventory.json (colonne « En service ») ; le dashboard évalue le même attribut avec
# un flake.lock à jour (colonne « Après update »).
let
  # Une option retirée ou cassée d'un module amont saute, au lieu de tout faire échouer.
  safe =
    v:
    let
      r = builtins.tryEval v;
    in
    if r.success then r.value else null;

  # L'entrée du flake qui fournit un paquet : celle dont la source contient sa définition
  # (`meta.position`) ; `self` pour un paquet de ce dépôt.
  sourceOf =
    p:
    let
      pos = safe (p.meta.position or null);
    in
    if !(builtins.isString pos) then
      null
    else
      lib.findFirst (n: lib.hasPrefix "${toString (inputs.${n}.outPath or "/nonexistent")}/" pos) null (
        lib.attrNames inputs
      );

  info =
    id: kind: p:
    let
      parsed = builtins.parseDrvName (safe p.name or "");
    in
    lib.optional (safe (lib.isDerivation p) == true) {
      inherit id kind;
      pname = safe (p.pname or parsed.name);
      version = safe (p.version or parsed.version);
      changelog = safe (p.meta.changelog or null);
      homepage = safe (p.meta.homepage or null);
      source = safe (sourceOf p);
    };

  enabled = v: safe (builtins.isAttrs v && (v.enable or false) == true) == true;

  # Une option déclarée et définie : un ancien nom (alias d'un module renommé) n'a pas de définition
  # et n'est jamais lu (sa lecture affiche un avertissement, ou interrompt l'évaluation).
  real = o: lib.isOption o && safe o.isDefined == true;

  # Les services d'un ensemble d'options : `enable` et `package` déclarés, puis la valeur ; ou ses
  # instances (services.authelia.instances.main…).
  fromSet =
    prefix: opts: cfg:
    lib.concatLists (
      lib.mapAttrsToList (
        name: o:
        if !(builtins.isAttrs o) || lib.isOption o then
          [ ]
        else
          lib.optionals (real (o.enable or null) && lib.isOption (o.package or null) && enabled cfg.${name}) (
            info "${prefix}.${name}" "service" (safe cfg.${name}.package)
          )
          ++ lib.optionals (real (o.instances or null)) (
            let
              instances = safe cfg.${name}.instances;
            in
            lib.concatLists (
              lib.mapAttrsToList (
                i: iv:
                lib.optionals (enabled iv && iv ? package) (
                  info "${prefix}.${name}.${i}" "service" (safe iv.package)
                )
              ) (if builtins.isAttrs instances then instances else { })
            )
          )
      ) opts
    );

  inventory =
    fromSet "services" options.services config.services
    ++ fromSet "virtualisation" options.virtualisation config.virtualisation
    ++ info "boot.kernel" "base" config.boot.kernelPackages.kernel
    ++ info "systemd" "base" config.systemd.package;
in
{
  options.systemSettings.admin.inventory = lib.mkOption {
    type = lib.types.listOf lib.types.attrs;
    readOnly = true;
    internal = true;
    default = inventory;
    description = "Paquets de ce qui tourne (onglet Mises à jour du dashboard).";
  };

  config = lib.mkIf config.systemSettings.admin.enable {
    environment.etc."dotfiles/inventory.json".text = builtins.toJSON inventory;
  };
}
