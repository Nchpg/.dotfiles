# Localisation du clone du dépôt par les commandes qui en lisent ou en
# exécutent des fichiers (genclean, rebuild, update, theme, dots, secrets) :
# $MY_FLAKE, sinon ~/.dotfiles.
#
#   flakeVar     : la seule ligne `flake=…`, pour qui fait ses propres
#                  contrôles (theme vérifie des fichiers à écrire, dots et
#                  secrets fonctionnent sans clone) ;
#   mkFlakeGuard : la même, plus l'échec propre si le script attendu n'y est
#                  pas exécutable — sans cette garde, un user sans clone
#                  (~guest, sudo -i) aurait un « No such file » peu clair au
#                  moment de l'exec.
let
  flakeVar = ''
    flake="''${MY_FLAKE:-$HOME/.dotfiles}"
  '';
in
{
  inherit flakeVar;

  mkFlakeGuard =
    {
      name, # nom de la commande, pour le message d'erreur, ex. "genclean"
      scriptName, # script attendu, relatif à la racine du flake, ex. "scripts/genclean.sh"
    }:
    flakeVar
    + ''
      if [ ! -x "$flake/${scriptName}" ]; then
        echo "${name} : flake introuvable ($flake/${scriptName}) — clone le dépôt ou définis MY_FLAKE." >&2
        exit 1
      fi
    '';
}
