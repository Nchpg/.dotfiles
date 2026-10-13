{
  pkgs-stable,
  myLib,
  ...
}:

{
  # Enrobe scripts/genclean.sh du dépôt pour le lancer depuis n'importe où.
  environment.systemPackages = [
    (pkgs-stable.writeShellScriptBin "genclean" ''
      set -euo pipefail
      ${myLib.mkFlakeGuard {
        name = "genclean";
        scriptName = "scripts/genclean.sh";
      }}
      exec "$flake/scripts/genclean.sh" "$@"
    '')
  ];
}
