{
  pkgs-stable,
  myLib,
  ...
}:

{
  # Enrobe ./genclean.sh du dépôt pour le lancer depuis n'importe où.
  environment.systemPackages = [
    (pkgs-stable.writeShellScriptBin "genclean" ''
      set -euo pipefail
      ${myLib.mkFlakeGuard {
        name = "genclean";
        scriptName = "genclean.sh";
      }}
      exec "$flake/genclean.sh" "$@"
    '')
  ];
}
