# root ne sert qu'aux dépannages en console locale : le strict nécessaire.
{
  config = {

    userSettings = {
      # stylix actif par défaut (cf. modules/user/stylix) : un dépannage en
      # console locale se fait dans les mêmes couleurs que la session
      # d'admin, pas dans un thème par défaut.

      editors.vim.enable = true;

      shell = {
        bash.enable = true;
        fish.enable = true;
        default = "bash";
      };
    };
  };
}
