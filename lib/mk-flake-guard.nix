# Bloc bash partagé par les commandes qui délèguent à un script du dépôt
# flake (genclean, rebuild, update, theme) : localise le clone via $MY_FLAKE (ou
# ~/.dotfiles) et échoue proprement si le script attendu n'y est pas
# exécutable — sans cette garde, un user sans clone (~guest, sudo -i) aurait
# un « No such file » peu clair au moment de l'exec. Pose la variable `flake`,
# à utiliser par l'appelant pour son propre exec final.
{
  name, # nom de la commande, pour le message d'erreur, ex. "genclean"
  scriptName, # script attendu, relatif à la racine du flake, ex. "scripts/genclean.sh"
}:
''
  flake="''${MY_FLAKE:-$HOME/.dotfiles}"
  if [ ! -x "$flake/${scriptName}" ]; then
    echo "${name} : flake introuvable ($flake/${scriptName}) — clone le dépôt ou définis MY_FLAKE." >&2
    exit 1
  fi
''
