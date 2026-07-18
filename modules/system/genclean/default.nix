{ pkgs-stable, ... }:

{
  # Commande `genclean` : enrobe le script ./genclean.sh du dépôt pour le
  # lancer depuis n'importe où (comme la commande `rebuild`). Le script garde
  # toute sa logique : choix du mode de purge des générations + GC + rebuild.
  # Le flake est cherché dans $MY_FLAKE, sinon ~/.dotfiles par défaut.
  environment.systemPackages = [
    (pkgs-stable.writeShellScriptBin "genclean" ''
      set -euo pipefail
      ${import ../../../lib/mk-flake-guard.nix {
        name = "genclean";
        scriptName = "genclean.sh";
      }}
      exec "$flake/genclean.sh" "$@"
    '')
  ];
}
