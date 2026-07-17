{ pkgs-stable, ... }:

{
  # Commande `genclean` : enrobe le script ./genclean.sh du dépôt pour le
  # lancer depuis n'importe où (comme la commande `rebuild`). Le script garde
  # toute sa logique : choix du mode de purge des générations + GC + rebuild.
  # Le flake est cherché dans $MY_FLAKE, sinon ~/.dotfiles par défaut.
  environment.systemPackages = [
    (pkgs-stable.writeShellScriptBin "genclean" ''
      set -euo pipefail
      flake="''${MY_FLAKE:-$HOME/.dotfiles}"
      # Garde explicite : lancé par un user sans clone (~guest, sudo -i), le
      # exec échouerait avec un « No such file » peu clair.
      if [ ! -x "$flake/genclean.sh" ]; then
        echo "genclean : flake introuvable ($flake/genclean.sh) — clone le dépôt ou définis MY_FLAKE." >&2
        exit 1
      fi
      exec "$flake/genclean.sh" "$@"
    '')
  ];
}
