{
  lib,
  config,
  pkgs-stable,
  myLib,
  ...
}:

{
  # Enrobe scripts/genclean.sh du dépôt pour le lancer depuis n'importe où, avec
  # gum et la palette Stylix pour ses menus (même rendu que `update`).
  environment.systemPackages = [
    (pkgs-stable.writeShellScriptBin "genclean" ''
      set -euo pipefail
      ${myLib.mkFlakeGuard {
        name = "genclean";
        scriptName = "scripts/genclean.sh";
      }}
      ${myLib.mkUpdateEnv {
        inherit lib config;
        inherit (pkgs-stable) gum;
      }}
      exec "$flake/scripts/genclean.sh" "$@"
    '')
  ];
}
