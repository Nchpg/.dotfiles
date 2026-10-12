{
  lib,
  config,
  pkgs-stable,
  myLib,
  ...
}:

{
  # Enrobe ./update.sh du dépôt pour le lancer depuis n'importe où, avec gum
  # et la palette Stylix (cf. lib/mk-update-env.nix).
  environment.systemPackages = [
    (pkgs-stable.writeShellScriptBin "update" ''
      set -euo pipefail
      ${myLib.mkFlakeGuard {
        name = "update";
        scriptName = "update.sh";
      }}
      ${myLib.mkUpdateEnv {
        inherit lib config;
        inherit (pkgs-stable) gum;
      }}
      exec "$flake/update.sh" "$@"
    '')
  ];
}
