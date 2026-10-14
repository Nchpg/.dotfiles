# Commande du PATH qui délègue à un script du dépôt : `update` ->
# scripts/update.sh, etc. Le script vit dans le clone (modifiable sans
# rebuild), l'enveloppe ne fait que le trouver (mkFlakeGuard), poser son
# environnement et l'exécuter avec les arguments tels quels.
{
  pkgs,
  name,
  # Script relatif à la racine du flake.
  scriptName ? "scripts/${name}.sh",
  # Bloc d'environnement gum (myLib.mkGumEnv), ou "" sans menus.
  gumEnv ? "",
  # Bash supplémentaire avant l'exec (exports propres à la commande).
  preamble ? "",
}:
pkgs.writeShellScriptBin name ''
  set -euo pipefail
  ${(import ./mk-flake-guard.nix).mkFlakeGuard { inherit name scriptName; }}
  ${gumEnv}
  ${preamble}
  exec "$flake/${scriptName}" "$@"
''
