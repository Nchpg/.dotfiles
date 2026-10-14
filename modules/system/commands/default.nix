{ lib, ... }:

# Catalogue des commandes du dépôt, affiché par `dots` (menu et `dots help`).
# Chaque commande s'y inscrit ELLE-MÊME, depuis son module : une commande
# absente de ce système (`theme` sans Stylix) n'y figure donc pas, sans
# masquage à l'exécution.
#
# Déclarée ici et pas dans dots/ : le chemin d'option `systemSettings.commands`
# est celui de ce dossier (cf. lib/check-option-paths.nix).
#
# Ce n'est QUE de la doc : chaque commande garde son propre parsing et son
# `--help`.
{
  options.systemSettings.commands = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          desc = lib.mkOption {
            type = lib.types.str;
            description = "Description d'une ligne, dans la liste des commandes.";
          };

          order = lib.mkOption {
            type = lib.types.int;
            description = "Rang dans le menu de `dots` (croissant).";
          };

          examples = lib.mkOption {
            # [ ligne de commande, explication ] ; `<…>` dans la ligne = valeur
            # demandée à l'exécution (gum input).
            type = lib.types.listOf (lib.types.listOf lib.types.str);
            default = [ ];
            description = "Usages courants proposés par le menu, avec leur explication.";
          };
        };
      }
    );
    default = { };
    description = "Commandes du dépôt présentées par `dots`, par nom.";
  };
}
