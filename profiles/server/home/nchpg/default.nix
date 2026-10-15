# Session d'administration distante : shell, éditeur, git. Rien de graphique
# (pas de terminal : sans écran, il ne ferait que tirer la pile GUI dans le
# store).
{
  config = {

    userSettings = {
      # stylix : actif par défaut (cf. modules/user/stylix), y compris ici
      # pour neovim/tmux/bat.

      # neovim et pas vim : c'est le même éditeur que sur gram (mêmes
      # raccourcis, mêmes LSP), et `vimAlias` garde `vim` fonctionnel — donc
      # le EDITOR=vim de modules/user/home-manager ouvre bien nvim.
      editors.neovim.enable = true;

      git = {
        enable = true;
        userName = "nathan.champagne";
        userEmailSops = "git/email";
      };

      agents = {
        claude = {
          enable = true;
          statusline.enable = true;
          settings.preferredNotifChannel = "notifications_disabled";
        };
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
