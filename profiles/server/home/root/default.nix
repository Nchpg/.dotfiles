{ pkgs-stable, ... }:

# root ne sert qu'aux dépannages en console locale : le strict nécessaire.
{
  config = {

    userSettings = {
      defaultPkgs = pkgs-stable;

      editors.vim.enable = true;

      shell = {
        bash.enable = true;
        fish.enable = true;
        default = "bash";
      };
    };
  };
}
