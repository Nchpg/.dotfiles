{ inputs, ... }:

# Le COMMIT de dotfiles dont ce système est construit, gravé dans le système :
# `nixos-version --configuration-revision` le rend. C'est ce qui permet à
# `dotstate` (modules/user/shell/dotstate) de dire, sans rien réévaluer, si ce
# qui tourne correspond à ce qu'il y a dans le dépôt.
#
# `dirtyRev` (« <commit>-dirty ») quand le build part d'un arbre avec des
# modifications non commitées : le système peut alors contenir autre chose que
# ce commit, et l'indicateur le dit.
#
# Conséquence : chaque commit donne un système (un peu) différent, donc une
# génération de plus au rebuild suivant, même sans autre changement. C'est le
# prix d'un état vérifiable, et l'activation n'a rien à redémarrer pour si peu.
{
  system.configurationRevision = inputs.self.rev or inputs.self.dirtyRev or null;
}
