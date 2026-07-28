{ pkgs-stable, ... }:

# root ne sert qu'aux dépannages en console locale : le strict nécessaire.
{
  config = {

    userSettings = {
      defaultPkgs = pkgs-stable;

      # Même palette que nchpg : un dépannage en console locale se fait dans
      # les mêmes couleurs que la session d'admin, pas dans un thème par
      # défaut. Aucun target GUI ici non plus (desktop.enable est faux).
      stylix.enable = true;

      editors.vim.enable = true;

      shell = {
        bash.enable = true;
        fish.enable = true;
        default = "bash";
      };
    };
  };
}
