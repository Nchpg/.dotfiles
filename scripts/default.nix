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
  settings ? { },
  # `theme` attend DOTS_GALLERY et DOTS_BROWSER dans `settings`.
  commands ? [
    "rebuild"
    "update"
    "genclean"
    "secrets"
    "dots"
  ],
}:

let
  # Affectations simples (pas `${VAR:=…}`) : l'environnement ne doit pas l'emporter sur le build.
  configFile = writeText "dots-config.sh" (
    "# Généré par scripts/default.nix : valeurs de ce système, cf. lib/env.sh.\n"
    + lib.concatStrings (lib.mapAttrsToList (n: v: "${n}=${lib.escapeShellArg v}\n") settings)
  );

  # `secrets` tourne en partie sous sudo : find/sed/grep/awk en tête du PATH ; nix, nixos-rebuild et sudo restent ceux du système.
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
  buildInputs = [ bash ];

  dontBuild = true;
  doCheck = true;
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
