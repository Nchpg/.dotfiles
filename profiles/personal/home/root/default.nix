{

  config = {

    userSettings = {
      windowManager.sway.enable = false;

      editors.vim.enable = true;

      # Identité (nom + email sops) : défaut du module git.
      git.enable = true;

      shell = {
        zsh.enable = true;
        bash.enable = true;
        fish.enable = true;
        default = "bash";
      };
    };
  };
}
