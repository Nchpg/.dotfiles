# Nom d'une cible du flake, à partir de son `target` ({ profile, host,
# variant }) — calculé ici une seule fois pour flake.nix (noms des
# nixosConfigurations), modules/system/network (hostname), la politique sops
# et le specialArg `target` lui-même. scripts/rebuild.sh fait le même calcul
# en bash, sur ses arguments.
lib: rec {
  # `personal-gram` : la machine, sans la variante. C'est aussi le hostname,
  # et le nom de la cible dark (nom historique).
  machine = target: "${target.profile}-${target.host}";

  # `personal-gram-light` : la cible complète, variante suffixée sauf dark.
  full =
    target:
    machine target + lib.optionalString ((target.variant or "dark") != "dark") "-${target.variant}";
}
