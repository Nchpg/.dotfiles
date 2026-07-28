{ pkgs-stable, ... }:

# Session d'administration distante : shell, éditeur, git. Rien de graphique
# (pas de terminal : sans écran, il ne ferait que tirer la pile GUI dans le
# store).
{
  config = {

    userSettings = {
      defaultPkgs = pkgs-stable;

      # Thémise vim/tmux/bat, dont les couleurs sont écrites en dur dans leur
      # config côté serveur — la palette ANSI, elle, vient du terminal client.
      # Sans ça, le `colorscheme base16-stylix` du module vim n'existe pas et
      # vim s'ouvre sur un E185. Les targets GTK/Qt/GNOME restent hors du
      # store : ils suivent systemSettings.desktop.enable, faux ici.
      stylix.enable = true;

      editors.vim.enable = true;

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
