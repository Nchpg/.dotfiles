{

  config = {

    userSettings = {
      windowManager.sway.enable = false;

      editors.vim.enable = true;

      git = {
        enable = true;
        userName = "nathan.champagne";
        userEmailSops = "git/email";
      };

      shell = {
        zsh.enable = true;
        bash.enable = true;
        fish.enable = true;
        default = "bash";
      };
    };
  };
}
