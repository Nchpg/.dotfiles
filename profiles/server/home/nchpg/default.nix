{
  config = {

    userSettings = {
      editors.neovim.enable = true;

      git = {
        enable = true;
        userName = "nathan.champagne";
        userEmailSops = "git/email";

        gh.enable = true;
      };

      agents = {
        claude = {
          enable = true;
          statusline.enable = true;
          settings = {
            preferredNotifChannel = "notifications_disabled";
            # Ultracode off par défaut, activé pour un seul prompt par le mot « ultracode ».
            enableWorkflows = true;
            workflowKeywordTriggerEnabled = true;
          };
        };

        herdr.enable = true;
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
