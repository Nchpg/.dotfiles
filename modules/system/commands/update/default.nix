{
  lib,
  config,
  pkgs-stable,
  myLib,
  ...
}:

{
  # Enrobe scripts/update.sh du dépôt pour le lancer depuis n'importe où, avec gum
  # et la palette Stylix (cf. lib/mk-update-env.nix).
  environment.systemPackages = [
    (pkgs-stable.writeShellScriptBin "update" ''
      set -euo pipefail
      ${myLib.mkFlakeGuard {
        name = "update";
        scriptName = "scripts/update.sh";
      }}
      ${myLib.mkUpdateEnv {
        inherit lib config;
        inherit (pkgs-stable) gum;
      }}
      exec "$flake/scripts/update.sh" "$@"
    '')
  ];
}
