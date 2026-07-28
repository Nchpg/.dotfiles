{ pkgs-stable, ... }:

# Session d'administration distante : shell, éditeur, git. Rien de graphique
# (pas de terminal ni de stylix : sans écran, ils ne feraient que tirer la
# pile GUI dans le store).
{
  config = {

    userSettings = {
      defaultPkgs = pkgs-stable;

      editors.vim.enable = true;

      git = {
        enable = true;
        userName = "nathan.champagne";
        userEmailSops = "git/email";
      };

      shell = {
        fish.enable = true;
        bash.enable = true;
        default = "fish";
      };

      tmux.enable = true;
    };
  };
}
