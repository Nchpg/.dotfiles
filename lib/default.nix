# Agrégateur des helpers du dépôt, injecté sous le nom `myLib` dans TOUS les
# modules (specialArgs système + extraSpecialArgs home-manager, cf. flake.nix)
# et consommé aussi par flake.nix lui-même.
#
# Raison d'être : les modules appelaient ces helpers par chemin relatif
# (`import ../../../../lib/mk-pkgs-option.nix`), donc la profondeur du dossier
# faisait partie du code — déplacer un module cassait ses imports, et une
# erreur de comptage de `../` ne se voyait qu'à l'éval. Passer par un argument
# rend les modules insensibles à leur position dans l'arborescence.
#
# Les helpers qui ont besoin de `lib` le reçoivent ici une fois pour toutes
# (importAll, dirNames, nixFileNames) ; les autres prennent leurs arguments à
# l'appel, comme avant.
lib:

{
  inherit (import ./discover.nix lib) dirNames nixFileNames;

  importAll = import ./import-all.nix lib;

  assertSopsAvailable = import ./assert-sops-available.nix;
  checkOptionPaths = import ./check-option-paths.nix lib;
  checkSopsPolicy = import ./check-sops-policy.nix lib;
  contentHash = import ./content-hash.nix lib;
  deepMergeJsonActivation = import ./deep-merge-json-activation.nix;
  editorLspPackages = import ./editor-lsp-packages.nix;
  fetchPinned = import ./fetch-pinned.nix lib;
  inherit (import ./mk-flake-guard.nix) flakeVar mkFlakeGuard;
  mkEvalCheck = import ./mk-eval-check.nix lib;
  mkFloatingTuiLauncher = import ./mk-floating-tui-launcher.nix;
  mkIcon = import ./mk-icon.nix lib;
  mkInternalPorts = import ./mk-internal-ports.nix lib;
  optionEnabled = import ./option-enabled.nix lib;
  mkPackageModule = import ./mk-package-module.nix;
  mkPkgsOption = import ./mk-pkgs-option.nix;
  mkSecretEnvWrapper = import ./mk-secret-env-wrapper.nix lib;
  mkThemedIcon = import ./mk-themed-icon.nix;
  mkTerminalCmd = import ./mk-terminal-cmd.nix;
  mkTlsVhost = import ./mk-tls-vhost.nix;
  mkGumEnv = import ./mk-gum-env.nix;
  mkRepoCommand = import ./mk-repo-command.nix;
  mkTerminalShellBin = import ./mk-terminal-shell-bin.nix;
  mkTerminalShellOption = import ./mk-terminal-shell-option.nix;
  schemeColors = import ./scheme-colors.nix;
  sopsAudience = import ./sops-audience.nix lib;
  # Fonction bash anchors() (ancres de clés d'un .sops.yaml), partagée avec
  # init.sh qui la source depuis le clone ; embarquée au build par `secrets`.
  sopsAnchorsSh = builtins.readFile ../scripts/lib/sops-anchors.sh;
  sopsPolicy = import ./sops-policy.nix lib;
  targetName = import ./target-name.nix lib;
}
