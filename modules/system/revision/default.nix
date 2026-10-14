{ inputs, dotfilesContent, ... }:

# Ce dont ce système est construit, gravé dans le système, pour que `dotstate`
# (modules/user/dotstate) dise sans rien réévaluer si ce qui tourne
# correspond à ce qu'il y a dans le dépôt.
#
#   - le COMMIT, que rend `nixos-version --configuration-revision` ;
#     « <commit>-dirty » quand le build part d'un arbre avec des
#     modifications non commitées ;
#   - l'EMPREINTE DU CONTENU (lib/content-hash.nix), dans
#     /etc/dotfiles/content. Indispensable au cas « -dirty » : construire, puis
#     commiter ces mêmes modifications, donne un commit différent pour un
#     contenu identique. Sans elle, dotstate annonçait des commits « pas encore
#     déployés » qui l'étaient déjà.
#
# Conséquence : chaque commit donne un système (un peu) différent, donc une
# génération de plus au rebuild suivant, même sans autre changement. C'est le
# prix d'un état vérifiable, et l'activation n'a rien à redémarrer pour si peu.
{
  system.configurationRevision = inputs.self.rev or inputs.self.dirtyRev or null;
  environment.etc."dotfiles/content".text = dotfilesContent;
}
