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
  deepMergeJsonActivation = import ./deep-merge-json-activation.nix;
  mkFlakeGuard = import ./mk-flake-guard.nix;
  mkFloatingTuiLauncher = import ./mk-floating-tui-launcher.nix;
  mkIcon = import ./mk-icon.nix lib;
  mkInternalPorts = import ./mk-internal-ports.nix lib;
  optionEnabled = import ./option-enabled.nix lib;
  mkPkgsOption = import ./mk-pkgs-option.nix;
  mkTerminalCmd = import ./mk-terminal-cmd.nix;
  mkTlsVhost = import ./mk-tls-vhost.nix;
  mkTerminalShellBin = import ./mk-terminal-shell-bin.nix;
  mkTerminalShellOption = import ./mk-terminal-shell-option.nix;
  sopsPolicy = import ./sops-policy.nix lib;
}
