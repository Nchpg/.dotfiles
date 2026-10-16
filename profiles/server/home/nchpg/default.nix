{
  config = {

    userSettings = {
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
