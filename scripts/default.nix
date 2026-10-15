# Les commandes du dépôt (rebuild, update, genclean, secrets, dots, theme), en
# UN paquet : les scripts de ce dossier copiés tels quels dans le store, chacun
# enveloppé pour trouver ses dépendances en tête du PATH, plus lib/config.sh,
# les valeurs propres au système qui l'installe (cf. lib/env.sh).
#
# Tout ce que lancent ces commandes vient donc du même build : le script, ses
# bibliothèques (lib/, sourcées par chemin relatif) et ses outils. Pas de
# commande qui en interroge une autre pour deviner sa version, pas de
# bibliothèque lue dans le clone à l'exécution.
#
# Appelé par modules/system/commands (le système, avec ses valeurs) et par
# flake.nix (les apps `nix run .#rebuild` d'une machine neuve, sans).
{
  lib,
  stdenvNoCC,
  makeWrapper,
  shellcheck,
  writeText,
  bash,
  coreutils,
  findutils,
  gnused,
  gnugrep,
  gawk,
  git,
  jq,
  curl,
  gum,
  nvd,
  sops,
  age,
  # Valeurs de lib/config.sh, nom -> chaîne (DOTS_PROFILE…, cf. lib/env.sh).
  settings ? { },
  # Commandes installées dans bin/. `theme` attend DOTS_GALLERY et
  # DOTS_BROWSER dans `settings`.
  commands ? [
    "rebuild"
    "update"
    "genclean"
    "secrets"
    "dots"
  ],
}:

let
  # Affectations simples et non `${VAR:=…}` : une valeur de l'environnement
  # ne doit jamais l'emporter sur celle du build (cf. l'en-tête de secrets.sh).
  configFile = writeText "dots-config.sh" (
    "# Généré par scripts/default.nix : valeurs de ce système, cf. lib/env.sh.\n"
    + lib.concatStrings (lib.mapAttrsToList (n: v: "${n}=${lib.escapeShellArg v}\n") settings)
  );

  # En tête du PATH de chaque commande. `findutils`, `gnused`, `gnugrep` et
  # `gawk` aussi, et pas laissés au PATH ambiant : `secrets` s'exécute en
  # partie sous sudo, un `find` pris ailleurs y serait un binaire choisi à
  # l'exécution. `age` : relever ta clé publique (`secrets`). `nvd` : diff des
  # paquets après un rebuild. `nix`, `nixos-rebuild` et `sudo` restent ceux du
  # système (et `secrets` prend le nix figé DOTS_NIX).
  runtimePath = lib.makeBinPath [
    coreutils
    findutils
    gnused
    gnugrep
    gawk
    git
    jq
    curl
    gum
    nvd
    sops
    age
  ];
in
stdenvNoCC.mkDerivation {
  pname = "dotfiles-commands";
  version = "1";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.difference ./. ./default.nix;
  };

  nativeBuildInputs = [
    makeWrapper
    shellcheck
  ];
  # Pour patchShebangs (#!/usr/bin/env bash -> bash du store).
  buildInputs = [ bash ];

  dontBuild = true;
  doCheck = true;
  # Comme la CI, depuis une racine où les directives `source=scripts/lib/…`
  # se résolvent.
  checkPhase = ''
    runHook preCheck
    mkdir -p "$TMPDIR/check/scripts"
    cp -r . "$TMPDIR/check/scripts"
    (cd "$TMPDIR/check" && shellcheck scripts/*.sh scripts/lib/*.sh)
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    dir=$out/share/dotfiles/scripts
    mkdir -p "$dir" $out/bin
    cp -r . "$dir"
    install -m644 ${configFile} "$dir/lib/config.sh"
    for c in ${lib.escapeShellArgs commands}; do
      chmod +x "$dir/$c.sh"
      makeWrapper "$dir/$c.sh" "$out/bin/$c" --prefix PATH : ${runtimePath}
    done
    runHook postInstall
  '';

  meta.description = "Commandes du dépôt de config (rebuild, update, secrets…)";
}
